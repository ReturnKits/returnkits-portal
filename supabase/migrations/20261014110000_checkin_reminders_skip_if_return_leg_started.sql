-- Check-in reminders only fire while the return leg hasn't started.
-- Excludes orders with any return-leg entry in fulfilment_log, or any extra
-- return parcel in order_tracking_numbers that has left 'awaiting_scan'.
-- (return_in_transit status was already excluded via the status filter.)
create or replace function public.orders_needing_checkin()
 returns table(order_id uuid, checkin_type text)
 language sql stable set search_path to 'public'
as $function$
  with dispatched as (
    select o.id, o.return_method, o.collection_date, o.leaver_last_day,
           public.order_dispatched_at(o.id) as dispatched_at
    from public.orders o
    where o.fulfilment_status in ('dispatched','in_transit','delivered')
      and o.service_type = 'return'
      and not exists (
        select 1 from jsonb_array_elements(coalesce(o.fulfilment_log, '[]'::jsonb)) e
        where e->'detail'->>'leg' = 'return'
      )
      and not exists (
        select 1 from public.order_tracking_numbers t
        where t.order_id = o.id and t.leg = 'return' and t.status <> 'awaiting_scan'
      )
  ),
  eligible_by_sla as (
    select id, 'checkin_sent'::text as checkin_type
    from dispatched
    where dispatched_at is not null
      and (
        (return_method = 'collection' and collection_date is not null
         and collection_date < (now() at time zone 'Europe/London')::date)
        or
        (return_method = 'drop_off'
         and public.add_working_days(dispatched_at::date, 3) <= (now() at time zone 'Europe/London')::date
         and (leaver_last_day is null or leaver_last_day <= (now() at time zone 'Europe/London')::date))
      )
  ),
  last_nudge as (
    select order_id, max(created_at) as last_sent_at
    from public.communication_log
    where type = 'checkin_sent' and status in ('sent','delivered')
    group by order_id
  )
  select e.id, e.checkin_type from eligible_by_sla e
  left join last_nudge n on n.order_id = e.id
  where n.last_sent_at is null or n.last_sent_at < now() - interval '3 days';
$function$;
revoke all on function public.orders_needing_checkin() from public, anon, authenticated;
grant execute on function public.orders_needing_checkin() to postgres, service_role;
