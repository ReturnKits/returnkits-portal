-- Restructures orders_needing_checkin()'s eligibility rule for return
-- orders, in response to a direct user question ("if you were to
-- restructure the email reminders, how would you structure them? based on
-- the information on the order that is provided when placing an order").
--
-- Two real gaps in the previous single-shape rule (5 working days since
-- dispatch, then every 3 days, for every 'return' order regardless of any
-- other order-level data):
--
-- 1. leaver_last_day is captured at order creation but was never used here.
--    A return kit often arrives before the leaver's own last day -- they
--    still need the device until then, so a "please send it back" nudge
--    firing purely off the dispatch-date SLA can land while the employee
--    is still using it for work. The rule now also requires
--    leaver_last_day (when set) to have passed.
--
-- 2. return_method/collection_date (added earlier the same day, see
--    20260820130000) were captured but not read here either. A
--    courier-collection order has nothing for anyone to "post back", so
--    reminding on the same dispatch-date SLA a drop-off order uses makes
--    no sense before the collection has even happened. Collection orders
--    now become eligible purely off collection_date having passed (not
--    the 5-working-day SLA at all -- a collection could be booked well
--    inside or well outside that window) with a one-day buffer (< today,
--    not <= today) so a same-day tracking update from Sendcloud has time
--    to land before this fires and produces a false "missed collection".
--
-- send-order-email's own branching (courier vs drop-off copy, no_email
-- deep link) reads return_method/collection_date directly off the order
-- row it already selects -- this migration only changes which orders are
-- SURFACED to it and when, not what gets rendered once they are.
--
-- Return shape is unchanged (order_id uuid, checkin_type text), so this is
-- a plain CREATE OR REPLACE, not a DROP+recreate -- Postgres only forces a
-- drop when the identity arguments or return type change, neither of
-- which is true here. Grants re-verified via information_schema and
-- re-applied explicitly below anyway, matching this project's own
-- established discipline for every function touched in this file's
-- history, even when not strictly required.

create or replace function public.orders_needing_checkin()
returns table(order_id uuid, checkin_type text)
language sql
stable
set search_path to 'public'
as $function$
  with dispatched as (
    select
      o.id,
      o.service_type,
      o.return_method,
      o.collection_date,
      o.leaver_last_day,
      public.order_dispatched_at(o.id) as dispatched_at
    from public.orders o
    where o.fulfilment_status = 'dispatched'
  ),
  eligible_by_sla as (
    select
      id,
      case when service_type = 'return' then 'checkin_sent' else 'checkin_received' end as checkin_type
    from dispatched
    where dispatched_at is not null
      and (
        -- ship_to_new_employee: unchanged, dispatch-date SLA only.
        (
          service_type <> 'return'
          and public.add_working_days(dispatched_at::date, 5) <= (now() at time zone 'Europe/London')::date
        )
        or
        -- return, courier collection: gated on the scheduled collection
        -- date having passed (plus a one-day buffer), never on the
        -- dispatch-date SLA -- see the migration header above.
        (
          service_type = 'return'
          and return_method = 'collection'
          and collection_date is not null
          and collection_date < (now() at time zone 'Europe/London')::date
        )
        or
        -- return, drop-off: existing 5-working-day SLA, but never before
        -- the leaver's own last day -- see the migration header above.
        (
          service_type = 'return'
          and return_method = 'drop_off'
          and public.add_working_days(dispatched_at::date, 5) <= (now() at time zone 'Europe/London')::date
          and (leaver_last_day is null or leaver_last_day <= (now() at time zone 'Europe/London')::date)
        )
      )
  ),
  last_nudge as (
    select order_id, type, max(created_at) as last_sent_at
    from public.communication_log
    where type in ('checkin_sent', 'checkin_received')
      and status in ('sent', 'delivered')
    group by order_id, type
  )
  select e.id, e.checkin_type
  from eligible_by_sla e
  left join last_nudge n on n.order_id = e.id and n.type = e.checkin_type
  where n.last_sent_at is null or n.last_sent_at < now() - interval '3 days';
$function$;

-- Re-apply exact grants (postgres implicit owner + service_role, no
-- anon/authenticated) -- confirmed via information_schema.routine_privileges
-- against the hosted database before writing this migration.
revoke all on function public.orders_needing_checkin() from public, anon, authenticated;
grant execute on function public.orders_needing_checkin() to service_role;
