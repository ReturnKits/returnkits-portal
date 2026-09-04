-- Migration: route return-order check-in reminders to the employee first
-- (falling back to the customer only when the employee can't be reached),
-- and remove the ship-to-new-employee "has it arrived?" reminder entirely
-- in favour of the existing Sendcloud tracking auto-complete path.
--
-- Direct user request, 20260827: the portal's own communication log already
-- gives the ordering company full visibility into an order's status -- they
-- shouldn't be pestered with check-in emails on top of that when the
-- employee (who has no portal access at all) can be reminded directly
-- instead. Two explicit follow-up decisions confirmed with the user before
-- building this:
--   1. When the employee can't be reached (notify_employee off, or no email
--      on file), the customer still gets a fallback nudge -- an order
--      should never go completely unreminded just because the employee
--      channel isn't available.
--   2. The "has it arrived?" reminder (ship_to_new_employee orders) is cut
--      entirely rather than kept customer-facing or moved to the employee
--      (there's no employee equivalent -- it's asking the portal admin to
--      confirm receipt themselves). Sendcloud's "delivered" auto-complete
--      (see the 20260813 "delivered auto-completes the order" decision)
--      already marks these orders completed automatically off the outbound
--      leg's tracking, backed by both the real-time webhook and the hourly
--      scheduled poll fallback -- so the manual "please confirm" ask is now
--      genuinely redundant with a working automated signal, not a needed
--      safety net.
--
-- orders_needing_checkin() is narrowed to return orders / checkin_sent only
-- -- the ship_to_new_employee branch and the 'checkin_received' checkin_type
-- are removed outright, not just left unused, matching this project's own
-- practice of removing genuinely dead paths (see confirm_sent's full
-- removal, 20260811090000). send-order-email's routing between customer and
-- employee for checkin_sent is handled in that Edge Function, not here --
-- this migration only narrows which orders/what type ever reach it.
create or replace function public.orders_needing_checkin()
returns table(order_id uuid, checkin_type text)
language sql
stable
set search_path to 'public'
as $function$
  with dispatched as (
    select
      o.id,
      o.return_method,
      o.collection_date,
      o.leaver_last_day,
      public.order_dispatched_at(o.id) as dispatched_at
    from public.orders o
    where o.fulfilment_status = 'dispatched'
      and o.service_type = 'return'
  ),
  eligible_by_sla as (
    select
      id,
      'checkin_sent'::text as checkin_type
    from dispatched
    where dispatched_at is not null
      and (
        -- courier collection: gated on the scheduled collection date having
        -- passed (plus a one-day buffer), never on the dispatch-date SLA.
        (
          return_method = 'collection'
          and collection_date is not null
          and collection_date < (now() at time zone 'Europe/London')::date
        )
        or
        -- drop-off: existing 5-working-day SLA, but never before the
        -- leaver's own last day.
        (
          return_method = 'drop_off'
          and public.add_working_days(dispatched_at::date, 5) <= (now() at time zone 'Europe/London')::date
          and (leaver_last_day is null or leaver_last_day <= (now() at time zone 'Europe/London')::date)
        )
      )
  ),
  last_nudge as (
    select order_id, max(created_at) as last_sent_at
    from public.communication_log
    where type = 'checkin_sent'
      and status in ('sent', 'delivered')
    group by order_id
  )
  select e.id, e.checkin_type
  from eligible_by_sla e
  left join last_nudge n on n.order_id = e.id
  where n.last_sent_at is null or n.last_sent_at < now() - interval '3 days';
$function$;

-- Grants re-verified, not just assumed, matching this project's own
-- standing discipline: confirmed via information_schema.routine_privileges
-- before this migration that only postgres/service_role held EXECUTE
-- (create or replace preserves existing grants for an unchanged signature,
-- but this is re-applied explicitly anyway per the project's own hard
-- lesson about CREATE OR REPLACE FUNCTION not always carrying grants
-- forward safely).
revoke all on function public.orders_needing_checkin() from public, anon, authenticated;
grant execute on function public.orders_needing_checkin() to service_role;
