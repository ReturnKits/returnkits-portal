-- ============================================================================
-- mark_return_completed — staff-facing (Retool) close-out for return orders.
--
-- Gap exposed by 20260811090000_remove_confirm_sent.sql: once confirm_sent
-- was removed, return orders had no path from 'dispatched' to 'completed' at
-- all -- nothing in the schema could advance them. ship_to_new_employee
-- orders still close themselves out via the customer's confirm_received;
-- return orders now rely entirely on a human (until Sendcloud tracking is
-- built) confirming the device has physically arrived back at ReturnKits.
--
-- Same auth model and shape as mark_order_dispatched/update_order_tracking:
-- service_role gate + assert_internal_actor, single state transition,
-- logged to both fulfilment_log (customer-facing timeline) and audit_log.
-- Deliberately narrow -- only 'dispatched' -> 'completed' on a return order,
-- nothing else. ship_to_new_employee orders are refused; confirm_received is
-- still the only way those close out.
-- ============================================================================

create or replace function public.mark_return_completed(
  p_order_id uuid,
  p_actor_id uuid
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
    raise exception 'mark_return_completed can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if v_order.service_type <> 'return' then
    raise exception 'mark_return_completed only applies to return orders';
  end if;

  if v_order.fulfilment_status <> 'dispatched' then
    raise exception 'Order % is not awaiting completion (currently %)', p_order_id, v_order.fulfilment_status;
  end if;

  v_before := to_jsonb(v_order);

  v_log_entry := jsonb_build_object(
    'action', 'return_received',
    'actor_id', p_actor_id,
    'at', now(),
    'detail', '{}'::jsonb
  );

  update public.orders
  set fulfilment_status = 'completed',
      fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
  where id = p_order_id;

  perform public.log_audit(
    p_actor_id, 'order.mark_return_completed', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;

revoke all on function public.mark_return_completed(uuid, uuid) from public;
revoke execute on function public.mark_return_completed(uuid, uuid) from anon, authenticated;
