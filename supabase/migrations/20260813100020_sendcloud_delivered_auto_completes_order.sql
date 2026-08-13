-- Sendcloud "delivered" auto-completion (20260813).
--
-- Clarified with the user: return orders ship back to the ordering
-- company's own HQ/IT address (orders.return_address_id, an entry in
-- their own `addresses` table) -- never a ReturnKits warehouse. So a
-- courier's "delivered" scan on the return leg is as legitimate a
-- completion signal as it is on the outbound leg of a ship-to-new-employee
-- order: both mean "the parcel reached the company's own address", not
-- "ReturnKits has taken physical custody and inspected it". Both service
-- types now auto-complete symmetrically off the same Sendcloud event,
-- exactly mirroring what the existing manual endpoints already do
-- (confirm_received and mark_return_completed both jump straight to
-- fulfilment_status = 'completed', not through the unused 'delivered'
-- enum value) -- this closes the gap the implementation plan flagged:
-- "the real fix is Phase 6's Sendcloud tracking webhooks updating
-- fulfilment_status automatically instead of relying on manual
-- confirmation from someone without visibility."
--
-- Guarded exactly like the existing in_transit branch: only transitions
-- from 'dispatched' or 'in_transit' (a delivered scan landing on an
-- already-completed or cancelled order is a no-op, not an error -- same
-- idempotent-replay safety the sendcloud-webhook Edge Function already
-- relies on). ship_to_new_employee orders also get confirmed_received_at
-- stamped with the event time (confirmed_received_by stays null --
-- system-triggered, not a specific user's click) so the Lovable order
-- page's existing "confirmed received" data keeps meaning the same thing
-- regardless of whether a human clicked the button or Sendcloud reported
-- it first. Return orders don't get an equivalent confirmed_sent_at --
-- that field belongs to the removed confirm_sent flow and stays unused.
create or replace function public.apply_sendcloud_tracking_event(
  p_tracking_number text,
  p_carrier_code text,
  p_status_code text,
  p_status_description text,
  p_event_at timestamp with time zone
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_order public.orders%rowtype;
  v_leg text;
  v_normalized text;
  v_before jsonb;
  v_log_entry jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'apply_sendcloud_tracking_event can only be called by the Sendcloud webhook handler';
  end if;

  select * into v_order from public.orders
  where outbound_tracking_number = p_tracking_number
     or return_tracking_number = p_tracking_number
  order by created_at desc
  limit 1;

  if not found then
    return jsonb_build_object('matched', false, 'reason', 'no order with this tracking number');
  end if;

  v_leg := case when v_order.outbound_tracking_number = p_tracking_number then 'outbound' else 'return' end;

  select normalized_status into v_normalized
  from public.sendcloud_status_map
  where status_code = p_status_code;

  if v_normalized is null then
    return jsonb_build_object(
      'matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', false,
      'reason', 'unmapped status_code: ' || p_status_code
    );
  end if;

  if v_normalized = 'in_transit' and v_order.fulfilment_status = 'dispatched' then
    v_before := to_jsonb(v_order);

    v_log_entry := jsonb_build_object(
      'action', 'in_transit',
      'actor_id', null,
      'at', p_event_at,
      'detail', jsonb_build_object(
        'leg', v_leg,
        'carrier_code', p_carrier_code,
        'status_code', p_status_code,
        'status_description', p_status_description
      )
    );

    update public.orders
    set fulfilment_status = 'in_transit',
        fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
    where id = v_order.id;

    perform public.log_audit(
      null, 'order.sendcloud_in_transit', 'orders', v_order.id, v_before,
      (select to_jsonb(o) from public.orders o where o.id = v_order.id)
    );

    return jsonb_build_object('matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', true, 'new_status', 'in_transit');
  end if;

  if v_normalized = 'delivered' and v_order.fulfilment_status in ('dispatched', 'in_transit') then
    v_before := to_jsonb(v_order);

    v_log_entry := jsonb_build_object(
      'action', 'delivered',
      'actor_id', null,
      'at', p_event_at,
      'detail', jsonb_build_object(
        'leg', v_leg,
        'carrier_code', p_carrier_code,
        'status_code', p_status_code,
        'status_description', p_status_description
      )
    );

    if v_order.service_type = 'ship_to_new_employee' then
      update public.orders
      set fulfilment_status = 'completed',
          confirmed_received_at = p_event_at,
          fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
      where id = v_order.id;
    else
      update public.orders
      set fulfilment_status = 'completed',
          fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
      where id = v_order.id;
    end if;

    perform public.log_audit(
      null, 'order.sendcloud_delivered', 'orders', v_order.id, v_before,
      (select to_jsonb(o) from public.orders o where o.id = v_order.id)
    );

    return jsonb_build_object('matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', true, 'new_status', 'completed');
  end if;

  return jsonb_build_object(
    'matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', false,
    'reason', 'no eligible transition from ' || v_order.fulfilment_status || ' for normalized status ' || v_normalized
  );
end;
$function$;
