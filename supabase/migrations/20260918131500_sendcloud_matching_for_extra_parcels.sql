-- Extend both Sendcloud matching paths (real-time webhook + poll/"Check tracking
-- now") to also recognise a scan against an order_tracking_numbers row (a 2nd/3rd
-- parcel added via add_order_tracking_number), not just the order's own primary
-- outbound_tracking_number/return_tracking_number columns.
--
-- Purely additive: the existing primary-parcel branches are byte-identical to
-- what's live today. The new branch only runs when the primary lookup finds
-- nothing. An extra parcel's scan updates its own status/status_log on
-- order_tracking_numbers -- it never touches orders.fulfilment_status. Order-level
-- auto-complete stays keyed off the primary parcel only (see the previous
-- migration's own note on why that's deliberately out of scope for v1).

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
  v_carrier_name text;
  v_before jsonb;
  v_log_entry jsonb;
  v_extra public.order_tracking_numbers%rowtype;
  v_extra_normalized text;
  v_extra_log jsonb;
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
    -- Not the primary parcel on any order -- check whether it's a registered
    -- extra parcel before giving up.
    select * into v_extra from public.order_tracking_numbers
    where tracking_number = p_tracking_number
    order by created_at desc
    limit 1;

    if not found then
      return jsonb_build_object('matched', false, 'reason', 'no order with this tracking number');
    end if;

    select normalized_status into v_extra_normalized
    from public.sendcloud_status_map
    where status_code = p_status_code;

    if v_extra_normalized is null then
      return jsonb_build_object(
        'matched', true, 'order_id', v_extra.order_id, 'leg', v_extra.leg,
        'extra_parcel_id', v_extra.id, 'applied', false,
        'reason', 'unmapped status_code: ' || p_status_code
      );
    end if;

    if v_extra_normalized not in ('in_transit', 'delivered') then
      return jsonb_build_object(
        'matched', true, 'order_id', v_extra.order_id, 'leg', v_extra.leg,
        'extra_parcel_id', v_extra.id, 'applied', false,
        'reason', 'no eligible transition for normalized status ' || v_extra_normalized
      );
    end if;

    if v_extra.status = v_extra_normalized
       or (v_extra.status = 'delivered' and v_extra_normalized = 'in_transit') then
      return jsonb_build_object(
        'matched', true, 'order_id', v_extra.order_id, 'leg', v_extra.leg,
        'extra_parcel_id', v_extra.id, 'applied', false,
        'reason', 'already at status ' || v_extra.status
      );
    end if;

    select display_name into v_carrier_name
    from public.sendcloud_carrier_map
    where carrier_code = p_carrier_code;

    v_extra_log := jsonb_build_object(
      'status', v_extra_normalized,
      'at', p_event_at,
      'detail', jsonb_build_object(
        'carrier_code', p_carrier_code,
        'status_code', p_status_code,
        'status_description', p_status_description,
        'source', 'webhook'
      )
    );

    update public.order_tracking_numbers
    set status = v_extra_normalized,
        courier = coalesce(courier, v_carrier_name),
        status_log = status_log || jsonb_build_array(v_extra_log)
    where id = v_extra.id;

    perform public.log_audit(
      null, 'order_tracking_number.sendcloud_status_update', 'order_tracking_numbers', v_extra.id,
      jsonb_build_object('status', v_extra.status),
      jsonb_build_object('status', v_extra_normalized)
    );

    return jsonb_build_object(
      'matched', true, 'order_id', v_extra.order_id, 'leg', v_extra.leg,
      'extra_parcel_id', v_extra.id, 'applied', true, 'new_status', v_extra_normalized
    );
  end if;

  v_leg := case when v_order.outbound_tracking_number = p_tracking_number then 'outbound' else 'return' end;

  select display_name into v_carrier_name
  from public.sendcloud_carrier_map
  where carrier_code = p_carrier_code;

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
        outbound_courier = case when v_leg = 'outbound' then coalesce(outbound_courier, v_carrier_name) else outbound_courier end,
        return_courier = case when v_leg = 'return' then coalesce(return_courier, v_carrier_name) else return_courier end,
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
          outbound_courier = case when v_leg = 'outbound' then coalesce(outbound_courier, v_carrier_name) else outbound_courier end,
          return_courier = case when v_leg = 'return' then coalesce(return_courier, v_carrier_name) else return_courier end,
          fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
      where id = v_order.id;
    else
      update public.orders
      set fulfilment_status = 'completed',
          outbound_courier = case when v_leg = 'outbound' then coalesce(outbound_courier, v_carrier_name) else outbound_courier end,
          return_courier = case when v_leg = 'return' then coalesce(return_courier, v_carrier_name) else return_courier end,
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

revoke execute on function public.apply_sendcloud_tracking_event(text, text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_sendcloud_tracking_event(text, text, text, text, timestamptz) to service_role;


create or replace function public.apply_sendcloud_poll_result(
  p_order_id uuid,
  p_actor_id uuid,
  p_tracking_number text,
  p_carrier_code text,
  p_parent_status text,
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
  v_carrier_name text;
  v_before jsonb;
  v_log_entry jsonb;
  v_source text;
  v_extra public.order_tracking_numbers%rowtype;
  v_extra_normalized text;
  v_extra_log jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'apply_sendcloud_poll_result can only be called by the poll-sendcloud-tracking Edge Function';
  end if;

  if p_actor_id is not null then
    perform public.assert_internal_actor(p_actor_id);
  end if;
  v_source := case when p_actor_id is null then 'scheduled_poll' else 'poll' end;

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if v_order.outbound_tracking_number = p_tracking_number then
    v_leg := 'outbound';
  elsif v_order.return_tracking_number = p_tracking_number then
    v_leg := 'return';
  else
    -- Not the primary parcel on this order -- check whether it's a registered
    -- extra parcel on this same order before giving up.
    select * into v_extra from public.order_tracking_numbers
    where order_id = p_order_id and tracking_number = p_tracking_number
    order by created_at desc
    limit 1;

    if not found then
      return jsonb_build_object(
        'matched', false, 'order_id', p_order_id,
        'reason', 'tracking number no longer matches this order -- stale poll result, not applied'
      );
    end if;

    select normalized_status into v_extra_normalized
    from public.sendcloud_poll_status_map
    where parent_status = p_parent_status;

    if v_extra_normalized is null then
      return jsonb_build_object(
        'matched', true, 'order_id', v_extra.order_id, 'leg', v_extra.leg,
        'extra_parcel_id', v_extra.id, 'applied', false,
        'reason', 'unmapped parent_status: ' || p_parent_status
      );
    end if;

    if v_extra_normalized not in ('in_transit', 'delivered') then
      return jsonb_build_object(
        'matched', true, 'order_id', v_extra.order_id, 'leg', v_extra.leg,
        'extra_parcel_id', v_extra.id, 'applied', false,
        'reason', 'no eligible transition for normalized status ' || v_extra_normalized
      );
    end if;

    if v_extra.status = v_extra_normalized
       or (v_extra.status = 'delivered' and v_extra_normalized = 'in_transit') then
      return jsonb_build_object(
        'matched', true, 'order_id', v_extra.order_id, 'leg', v_extra.leg,
        'extra_parcel_id', v_extra.id, 'applied', false,
        'reason', 'already at status ' || v_extra.status
      );
    end if;

    select display_name into v_carrier_name
    from public.sendcloud_carrier_map
    where carrier_code = p_carrier_code;

    v_extra_log := jsonb_build_object(
      'status', v_extra_normalized,
      'at', p_event_at,
      'detail', jsonb_build_object(
        'carrier_code', p_carrier_code,
        'parent_status', p_parent_status,
        'status_description', p_status_description,
        'source', v_source
      )
    );

    update public.order_tracking_numbers
    set status = v_extra_normalized,
        courier = coalesce(courier, v_carrier_name),
        status_log = status_log || jsonb_build_array(v_extra_log)
    where id = v_extra.id;

    perform public.log_audit(
      p_actor_id, 'order_tracking_number.poll_status_update', 'order_tracking_numbers', v_extra.id,
      jsonb_build_object('status', v_extra.status),
      jsonb_build_object('status', v_extra_normalized)
    );

    return jsonb_build_object(
      'matched', true, 'order_id', v_extra.order_id, 'leg', v_extra.leg,
      'extra_parcel_id', v_extra.id, 'applied', true, 'new_status', v_extra_normalized
    );
  end if;

  select display_name into v_carrier_name
  from public.sendcloud_carrier_map
  where carrier_code = p_carrier_code;

  select normalized_status into v_normalized
  from public.sendcloud_poll_status_map
  where parent_status = p_parent_status;

  if v_normalized is null then
    return jsonb_build_object(
      'matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', false,
      'reason', 'unmapped parent_status: ' || p_parent_status
    );
  end if;

  if v_normalized = 'in_transit' and v_order.fulfilment_status = 'dispatched' then
    v_before := to_jsonb(v_order);

    v_log_entry := jsonb_build_object(
      'action', 'in_transit',
      'actor_id', p_actor_id,
      'at', p_event_at,
      'detail', jsonb_build_object(
        'leg', v_leg,
        'carrier_code', p_carrier_code,
        'parent_status', p_parent_status,
        'status_description', p_status_description,
        'source', v_source
      )
    );

    update public.orders
    set fulfilment_status = 'in_transit',
        outbound_courier = case when v_leg = 'outbound' then coalesce(outbound_courier, v_carrier_name) else outbound_courier end,
        return_courier = case when v_leg = 'return' then coalesce(return_courier, v_carrier_name) else return_courier end,
        fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
    where id = v_order.id;

    perform public.log_audit(
      p_actor_id, 'order.poll_in_transit', 'orders', v_order.id, v_before,
      (select to_jsonb(o) from public.orders o where o.id = v_order.id)
    );

    return jsonb_build_object('matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', true, 'new_status', 'in_transit');
  end if;

  if v_normalized = 'delivered' and v_order.fulfilment_status in ('dispatched', 'in_transit') then
    v_before := to_jsonb(v_order);

    v_log_entry := jsonb_build_object(
      'action', 'delivered',
      'actor_id', p_actor_id,
      'at', p_event_at,
      'detail', jsonb_build_object(
        'leg', v_leg,
        'carrier_code', p_carrier_code,
        'parent_status', p_parent_status,
        'status_description', p_status_description,
        'source', v_source
      )
    );

    if v_order.service_type = 'ship_to_new_employee' then
      update public.orders
      set fulfilment_status = 'completed',
          confirmed_received_at = p_event_at,
          outbound_courier = case when v_leg = 'outbound' then coalesce(outbound_courier, v_carrier_name) else outbound_courier end,
          return_courier = case when v_leg = 'return' then coalesce(return_courier, v_carrier_name) else return_courier end,
          fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
      where id = v_order.id;
    else
      update public.orders
      set fulfilment_status = 'completed',
          outbound_courier = case when v_leg = 'outbound' then coalesce(outbound_courier, v_carrier_name) else outbound_courier end,
          return_courier = case when v_leg = 'return' then coalesce(return_courier, v_carrier_name) else return_courier end,
          fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
      where id = v_order.id;
    end if;

    perform public.log_audit(
      p_actor_id, 'order.poll_delivered', 'orders', v_order.id, v_before,
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

revoke execute on function public.apply_sendcloud_poll_result(uuid, uuid, text, text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_sendcloud_poll_result(uuid, uuid, text, text, text, text, timestamptz) to service_role;
