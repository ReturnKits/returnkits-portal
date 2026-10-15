-- Backfilled from the hosted project (applied there directly via apply_migration) so a local `db reset` reproduces hosted.
--
-- order_dispatched_at() only recognised a 'dispatched' fulfilment_log entry, so orders put into
-- 'dispatched' via the staff "Override status" action (which logs 'status_override') had no dispatch
-- date and were never picked up by orders_needing_checkin(). Fall back to a status_override entry
-- whose to_fulfilment_status is 'dispatched'. Latest matching entry wins, as before.
-- Same signature, so existing grants (postgres, service_role) are preserved.
create or replace function public.order_dispatched_at(p_order_id uuid)
 returns timestamp with time zone
 language sql
 stable
 set search_path to 'public'
as $function$
  select (entry->>'at')::timestamptz
  from public.orders o, jsonb_array_elements(o.fulfilment_log) entry
  where o.id = p_order_id
    and (
      entry->>'action' = 'dispatched'
      or (entry->>'action' = 'status_override'
          and entry->'detail'->>'to_fulfilment_status' = 'dispatched')
    )
  order by (entry->>'at')::timestamptz desc
  limit 1;
$function$;
