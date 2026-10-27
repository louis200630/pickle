-- Additive RPCs for pickle.html mixed pending booking payments.
-- Existing production RPCs and tables are unchanged.
begin;
create or replace function private.preview_pending_mixed_payment(p_entry_id uuid,p_amount integer,p_package_units integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare e public.financial_entries%rowtype; balance bigint; consumed bigint; priced_units bigint; revenue bigint; at_time timestamptz:=statement_timestamp();
begin
 if auth.uid() is null or not private.is_admin() then raise exception '僅管理員可調整付款'; end if;
 if p_amount is null or p_amount<0 or p_package_units is null or p_package_units<0 then raise exception '金額與套票次數需為非負整數'; end if;
 select * into e from public.financial_entries where id=p_entry_id;
 if not found or e.booking_id is null then raise exception '找不到報名財務紀錄'; end if;
 if e.status<>'pending' then raise exception '只能調整待確認紀錄'; end if;
 if not exists(select 1 from public.bookings b join public.sessions s on s.id=b.session_id where b.id=e.booking_id and b.status='active' and s.id=e.session_id and s.status='open') then raise exception '此報名或場次已不可調整'; end if;
 if not exists(select 1 from public.players where id=e.player_id and account_status='active') then raise exception '球友帳號已停用'; end if;
 select coalesce(sum(package_delta),0),coalesce(sum(-package_delta) filter(where package_delta<0),0)
 into balance,consumed from public.financial_entries where player_id=e.player_id and status='confirmed';
 if p_package_units>balance then raise exception '套票餘額不足，目前剩 % 次',balance; end if;
 with credits as (
 select id,amount,package_delta,package_plan_id,booking_id,coalesce(confirmed_at,created_at) as credit_time,
 sum(package_delta::bigint) over(order by coalesce(confirmed_at,created_at),created_at,id)-package_delta as first_unit,
 sum(package_delta::bigint) over(order by coalesce(confirmed_at,created_at),created_at,id) as after_last_unit
 from public.financial_entries where player_id=e.player_id and status='confirmed' and package_delta>0
 ), matched as (
 select *,greatest(first_unit,consumed) as lo,least(after_last_unit,consumed+p_package_units) as hi
 from credits where first_unit<consumed+p_package_units and after_last_unit>consumed and credit_time<=at_time
 )
 select coalesce(sum(hi-lo) filter(where package_plan_id is not null and booking_id is null and amount>=0),0),
 coalesce(sum(floor((hi-first_unit)::numeric*amount/package_delta)-floor((lo-first_unit)::numeric*amount/package_delta))
 filter(where package_plan_id is not null and booking_id is null and amount>=0),0)
 into priced_units,revenue from matched where hi>lo;
 return jsonb_build_object('cash_amount',p_amount,'package_units',p_package_units,'package_balance',balance,
 'package_revenue',revenue,'manual_review_units',p_package_units-priced_units,
 'total_revenue',case when priced_units=p_package_units then p_amount+revenue else null end);
end $$;
create or replace function public.preview_pending_mixed_payment(p_entry_id uuid,p_amount integer,p_package_units integer)
returns jsonb language sql stable security invoker set search_path='' as $$
 select private.preview_pending_mixed_payment(p_entry_id,p_amount,p_package_units);
$$;
create or replace function private.update_pending_mixed_payment(p_entry_id uuid,p_amount integer,p_package_delta integer,p_note text default null)
returns void language plpgsql security definer set search_path='' as $$
declare e public.financial_entries%rowtype; sid uuid;
begin
 if auth.uid() is null or not private.is_admin() then raise exception '僅管理員可調整付款'; end if;
 if p_amount is null or p_amount<0 or p_package_delta is null or p_package_delta>0 or p_package_delta=-2147483648 then raise exception '金額與套票扣除次數不正確'; end if;
 select session_id into sid from public.financial_entries where id=p_entry_id;
 if sid is null then raise exception '找不到場次財務紀錄'; end if;
 perform 1 from public.sessions where id=sid for update;
 select * into e from public.financial_entries where id=p_entry_id for update;
 perform 1 from public.players where id=e.player_id for update;
 perform private.preview_pending_mixed_payment(p_entry_id,p_amount,-p_package_delta);
 update public.financial_entries set amount=p_amount,package_delta=p_package_delta,note=coalesce(nullif(trim(p_note),''),note) where id=p_entry_id;
end $$;
create or replace function public.update_pending_mixed_payment(p_entry_id uuid,p_amount integer,p_package_delta integer,p_note text default null)
returns void language sql security invoker set search_path='' as $$
 select private.update_pending_mixed_payment(p_entry_id,p_amount,p_package_delta,p_note);
$$;
revoke all on function private.preview_pending_mixed_payment(uuid,integer,integer),public.preview_pending_mixed_payment(uuid,integer,integer),private.update_pending_mixed_payment(uuid,integer,integer,text),public.update_pending_mixed_payment(uuid,integer,integer,text) from public,anon;
grant execute on function private.preview_pending_mixed_payment(uuid,integer,integer),public.preview_pending_mixed_payment(uuid,integer,integer),private.update_pending_mixed_payment(uuid,integer,integer,text),public.update_pending_mixed_payment(uuid,integer,integer,text) to authenticated;
notify pgrst,'reload schema';
commit;