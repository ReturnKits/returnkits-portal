-- ============================================================================
-- Payment gate on dispatch (user decision 20260811): "I don't want to be
-- fulfilling if it hasn't been paid yet." mark_order_dispatched now refuses
-- to run unless payment_status = 'paid', no exceptions.
--
-- Gap this exposed: payment_status is only ever set to 'paid' by
-- record_stripe_payment (the Stripe webhook). Orders created manually in
-- Retool via create_internal_order (source = 'internal_staff') never go
-- through Stripe checkout at all, so a blanket "must be paid" block would
-- make manually-created orders permanently undispatchable.
--
-- Fix (user decision): a new staff-only RPC, mark_order_paid, gives staff an
-- explicit, logged way to mark an order paid outside the Stripe flow --
-- for invoiced/offline/comped arrangements. Same auth pattern as every
-- other Retool write (service_role + assert_internal_actor). This keeps the
-- payment gate universal (every order needs SOME explicit paid signal
-- before dispatch) rather than carving out a silent exemption for one
-- order source.
-- ============================================================================

create or replace function public.mark_order_paid(
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
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'mark_order_paid can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if v_order.payment_status <> 'pending' then
    raise exception 'Order % is not pending payment (currently %)', p_order_id, v_order.payment_status;
  end if;

  v_before := to_jsonb(v_order);

  update public.orders
  set payment_status = 'paid'
  where id = p_order_id;

  perform public.log_audit(
    p_actor_id, 'order.mark_paid', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;

revoke all on function public.mark_order_paid(uuid, uuid) from public;
revoke execute on function public.mark_order_paid(uuid, uuid) from anon, authenticated;

-- ----------------------------------------------------------------------------
-- mark_order_dispatched: add the payment guard. Everything else unchanged.
-- ----------------------------------------------------------------------------
create or replace function public.mark_order_dispatched(
  p_order_id uuid,
  p_actor_id uuid,
  p_courier text,
  p_tracking_number text,
  p_tracking_url text default null
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
    raise exception 'mark_order_dispatched can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if v_order.fulfilment_status <> 'awaiting_dispatch' then
    raise exception 'Order % is not awaiting dispatch (currently %)', p_order_id, v_order.fulfilment_status;
  end if;

  if v_order.payment_status <> 'paid' then
    raise exception 'Order % has not been paid (payment_status: %) -- use mark_order_paid first if this is a legitimate offline/comped order', p_order_id, v_order.payment_status;
  end if;

  v_before := to_jsonb(v_order);

  v_log_entry := jsonb_build_object(
    'action', 'dispatched',
    'actor_id', p_actor_id,
    'at', now(),
    'detail', jsonb_build_object('courier', p_courier, 'tracking_number', p_tracking_number)
  );

  if v_order.service_type = 'return' then
    update public.orders
    set fulfilment_status = 'dispatched',
        return_courier = p_courier,
        return_tracking_number = p_tracking_number,
        return_tracking_url = p_tracking_url,
        fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
    where id = p_order_id;
  else
    update public.orders
    set fulfilment_status = 'dispatched',
        outbound_courier = p_courier,
        outbound_tracking_number = p_tracking_number,
        outbound_tracking_url = p_tracking_url,
        fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
    where id = p_order_id;
  end if;

  perform public.log_audit(
    p_actor_id, 'order.dispatch', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;
