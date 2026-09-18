-- Genuine gap found while wiring up multi-parcel tracking: neither the
-- manual "Check Tracking Now" click nor the hourly scheduled poll ever
-- looked at order_tracking_numbers -- both only ever polled an order's own
-- primary outbound_tracking_number/return_tracking_number. Since Sendcloud
-- webhooks have never once reached this system in production (0 rows in
-- sendcloud_webhook_events, per the 20260813200000 poll-fallback migration's
-- own finding), an extra parcel's status would have been permanently stuck
-- at 'awaiting_scan' -- there'd be no live path to ever update it. This
-- migration extends orders_needing_tracking_poll() to also flag an order
-- that has at least one non-delivered extra parcel (even if, in the
-- unlikely edge case, its own primary tracking columns are both null); the
-- poll-sendcloud-tracking Edge Function is updated separately (not in this
-- migration -- deployed alongside it, though the deploy itself is blocked
-- as of 20260918 by a tool-level bug, see that file's own header comment)
-- to actually enumerate and poll those extra tracking numbers too, for both
-- the manual and scheduled paths.

create or replace function public.orders_needing_tracking_poll()
returns table(order_id uuid, reference text, outbound_tracking_number text, return_tracking_number text)
language sql
stable
set search_path to 'public'
as $function$
  select o.id, o.reference, o.outbound_tracking_number, o.return_tracking_number
  from public.orders o
  where o.fulfilment_status in ('dispatched', 'in_transit')
    and (
      o.outbound_tracking_number is not null
      or o.return_tracking_number is not null
      or exists (
        select 1 from public.order_tracking_numbers otn
        where otn.order_id = o.id and otn.status <> 'delivered'
      )
    );
$function$;

revoke execute on function public.orders_needing_tracking_poll() from public, anon, authenticated;
grant execute on function public.orders_needing_tracking_poll() to service_role;
