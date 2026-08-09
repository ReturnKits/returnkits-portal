-- ============================================================================
-- update_order_tracking — lets Retool staff set or correct EITHER tracking
-- leg (outbound: the box ReturnKits ships out; return: the device coming
-- back) independently of the dispatch/confirm state machine.
--
-- Why this exists as its own function rather than reusing
-- mark_order_dispatched/confirm_sent: those two are state-transition
-- functions (they require a specific fulfilment_status and move it forward).
-- Staff sometimes just need to correct a mistyped tracking number, or add
-- the return tracking number themselves because a customer phoned it in
-- instead of using the portal's Confirm Sent flow — that shouldn't require
-- (or be blocked by) a status transition. Every field is optional and only
-- overwrites what's actually passed (coalesce against the existing value),
-- so a partial correction doesn't clobber the other leg's tracking.
--
-- Same auth model as the rest of the Retool write API (service_role gate +
-- assert_internal_actor), same dual logging (audit_log + fulfilment_log so
-- the customer-facing timeline in Lovable reflects staff corrections too).
-- ============================================================================

create or replace function public.update_order_tracking(
  p_order_id uuid,
  p_actor_id uuid,
  p_outbound_courier text default null,
  p_outbound_tracking_number text default null,
  p_outbound_tracking_url text default null,
  p_return_courier text default null,
  p_return_tracking_number text default null,
  p_return_tracking_url text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_before jsonb;
  v_log_entry jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'update_order_tracking can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if p_outbound_courier is null and p_outbound_tracking_number is null and p_outbound_tracking_url is null
     and p_return_courier is null and p_return_tracking_number is null and p_return_tracking_url is null then
    raise exception 'No tracking fields supplied to update';
  end if;

  v_before := to_jsonb(v_order);

  v_log_entry := jsonb_build_object(
    'action', 'tracking_updated',
    'actor_id', p_actor_id,
    'at', now(),
    'detail', jsonb_build_object(
      'outbound_courier', p_outbound_courier,
      'outbound_tracking_number', p_outbound_tracking_number,
      'return_courier', p_return_courier,
      'return_tracking_number', p_return_tracking_number
    )
  );

  update public.orders
  set outbound_courier = coalesce(p_outbound_courier, outbound_courier),
      outbound_tracking_number = coalesce(p_outbound_tracking_number, outbound_tracking_number),
      outbound_tracking_url = coalesce(p_outbound_tracking_url, outbound_tracking_url),
      return_courier = coalesce(p_return_courier, return_courier),
      return_tracking_number = coalesce(p_return_tracking_number, return_tracking_number),
      return_tracking_url = coalesce(p_return_tracking_url, return_tracking_url),
      fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
  where id = p_order_id;

  perform public.log_audit(
    p_actor_id, 'order.tracking_updated', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;

revoke all on function public.update_order_tracking(uuid, uuid, text, text, text, text, text, text) from public;
revoke execute on function public.update_order_tracking(uuid, uuid, text, text, text, text, text, text) from anon, authenticated;
