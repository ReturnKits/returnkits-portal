-- ============================================================================
-- Phase 5: check-in eligibility -- who needs a "have you sent it back?" or
-- "has it arrived?" nudge right now.
--
-- Thresholds are assumptions, not specified numerically in the architecture
-- doc (§21 gives "chase after 5 days" only as an illustrative example of why
-- working-day counting matters, not a locked number):
--   - First nudge: 5 working days after dispatch with no confirmation.
--   - Re-nudge cooldown: 3 calendar days between repeat nudges for the same
--     order, so an unresolved order gets chased periodically rather than
--     daily-spammed. Calendar days here, not working days -- this is a
--     spam-prevention throttle, not an SLA calculation, so bank-holiday
--     precision doesn't matter for it the way it does for the initial
--     dispatch-to-nudge threshold.
-- Flag to the user if these numbers should be different -- easy to change,
-- both live in orders_needing_checkin() below, nowhere else.
-- ============================================================================

create or replace function public.order_dispatched_at(p_order_id uuid)
returns timestamptz
language sql
stable
set search_path = public
as $$
  select (entry->>'at')::timestamptz
  from public.orders o, jsonb_array_elements(o.fulfilment_log) entry
  where o.id = p_order_id
    and entry->>'action' = 'dispatched'
  order by (entry->>'at')::timestamptz desc
  limit 1;
$$;

comment on function public.order_dispatched_at(uuid) is
  'Extracts the dispatch timestamp from fulfilment_log (there is no dedicated dispatched_at column -- Phase 4 logs it as a fulfilment_log entry with action=''dispatched''). Returns null if the order has never been dispatched.';

create or replace function public.orders_needing_checkin()
returns table (order_id uuid, checkin_type text)
language sql
stable
set search_path = public
as $$
  with dispatched as (
    select
      o.id,
      o.service_type,
      o.fulfilment_status,
      public.order_dispatched_at(o.id) as dispatched_at
    from public.orders o
    where o.fulfilment_status = 'dispatched'
  ),
  eligible_by_sla as (
    select id, service_type,
      case when service_type = 'return' then 'checkin_sent' else 'checkin_received' end as checkin_type
    from dispatched
    where dispatched_at is not null
      -- 5 working days have fully elapsed since the dispatch date.
      and public.add_working_days(dispatched_at::date, 5) <= (now() at time zone 'Europe/London')::date
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
$$;

comment on function public.orders_needing_checkin() is
  'Orders due a check-in nudge right now: dispatched >= 5 working days ago, still awaiting confirm_sent (returns) or confirm_received (ship-to-new-employee), and not nudged in the last 3 calendar days. Called by the send-checkin-notifications Edge Function on its pg_cron schedule.';

revoke all on function public.order_dispatched_at(uuid) from public;
revoke execute on function public.order_dispatched_at(uuid) from anon, authenticated;
revoke all on function public.orders_needing_checkin() from public;
revoke execute on function public.orders_needing_checkin() from anon, authenticated;
