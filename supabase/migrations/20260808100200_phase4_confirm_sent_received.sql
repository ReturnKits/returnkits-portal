-- ============================================================================
-- Phase 4: Confirm Sent / Confirm Received — customer-facing (Lovable), not
-- Retool. Opposite auth model from mark_order_dispatched/create_internal_order:
-- these run as the signed-in customer, using their real auth.uid() and
-- current_company(), exactly like create_order(). No service_role gate.
--
-- Every order is dispatched the same way regardless of service_type
-- (mark_order_dispatched populates outbound_* -- we always ship something
-- out first, either the new kit itself or an empty return-kit box). These
-- two functions are what advances an order past 'dispatched', and which one
-- applies depends on service_type:
--   - service_type = 'return'               -> confirm_sent (the leaver has
--     posted the old device back to us)
--   - service_type = 'ship_to_new_employee' -> confirm_received (the new
--     joiner has received their kit; nothing further needed from us)
-- ============================================================================

create or replace function public.confirm_sent(
  p_order_id uuid,
  p_return_tracking_number text default null
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
  if public.current_company() is null then
    raise exception 'Your account is not attached to a company yet.';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found or v_order.company_id <> public.current_company() then
    raise exception 'Order not found for your company';
  end if;

  if v_order.service_type <> 'return' then
    raise exception 'confirm_sent only applies to return orders';
  end if;

  if v_order.fulfilment_status <> 'dispatched' then
    raise exception 'Order is not awaiting a sent confirmation (currently %)', v_order.fulfilment_status;
  end if;

  v_before := to_jsonb(v_order);

  v_log_entry := jsonb_build_object(
    'action', 'confirmed_sent',
    'actor_id', auth.uid(),
    'at', now(),
    'detail', jsonb_build_object('return_tracking_number', p_return_tracking_number)
  );

  update public.orders
  set fulfilment_status = 'confirmed_sent',
      confirmed_sent_at = now(),
      confirmed_sent_by = auth.uid(),
      return_tracking_number = coalesce(p_return_tracking_number, return_tracking_number),
      fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
  where id = p_order_id;

  perform public.log_audit(
    auth.uid(), 'order.confirm_sent', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;

revoke all on function public.confirm_sent(uuid, text) from public;
grant execute on function public.confirm_sent(uuid, text) to authenticated;

create or replace function public.confirm_received(p_order_id uuid)
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
  if public.current_company() is null then
    raise exception 'Your account is not attached to a company yet.';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found or v_order.company_id <> public.current_company() then
    raise exception 'Order not found for your company';
  end if;

  if v_order.service_type <> 'ship_to_new_employee' then
    raise exception 'confirm_received only applies to ship-to-new-employee orders';
  end if;

  if v_order.fulfilment_status <> 'dispatched' then
    raise exception 'Order is not awaiting a received confirmation (currently %)', v_order.fulfilment_status;
  end if;

  v_before := to_jsonb(v_order);

  v_log_entry := jsonb_build_object(
    'action', 'confirmed_received',
    'actor_id', auth.uid(),
    'at', now(),
    'detail', '{}'::jsonb
  );

  -- No further staff step needed once a ship-to-new-employee kit is
  -- confirmed received -- straight to 'completed', unlike a return, which
  -- still needs the physical device to arrive and be checked in by staff.
  update public.orders
  set fulfilment_status = 'completed',
      confirmed_received_at = now(),
      confirmed_received_by = auth.uid(),
      fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
  where id = p_order_id;

  perform public.log_audit(
    auth.uid(), 'order.confirm_received', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;

revoke all on function public.confirm_received(uuid) from public;
grant execute on function public.confirm_received(uuid) to authenticated;
