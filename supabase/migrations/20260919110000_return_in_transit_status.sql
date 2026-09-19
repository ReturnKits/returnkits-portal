-- Adds a distinct 'return_in_transit' fulfilment_status for a return order's
-- SECOND leg: the moment the customer's own device is scanned in transit by
-- the courier on its way BACK to the ordering company, after the outbound
-- leg has already been delivered ("with employee"). Previously there was no
-- transition at all for this event -- the order just sat at 'delivered'
-- until the return was scanned fully delivered, with no visible progress in
-- between, and the pre-existing "return is on its way back" email
-- (return_in_transit type, built 20260814) depended on a precondition
-- (fulfilment_status = 'dispatched') that a return-leg-in-transit event can
-- essentially never satisfy once the outbound leg has already advanced the
-- order past 'dispatched' -- so in practice it rarely if ever fired.
--
-- Deliberately a NEW enum value rather than reusing 'in_transit': reusing it
-- would make the customer-facing step tracker jump BACKWARDS (from "With
-- employee" back to "On its way"), since 'in_transit' already means
-- "outbound leg moving" earlier in the same order's lifecycle.

begin;

alter table public.orders drop constraint orders_fulfilment_status_check;
alter table public.orders add constraint orders_fulfilment_status_check
  check (fulfilment_status = any (array[
    'awaiting_dispatch', 'dispatched', 'in_transit', 'delivered',
    'return_in_transit', 'confirmed_received', 'completed', 'cancelled'
  ]));

-- apply_sendcloud_tracking_event(): add the delivered -> return_in_transit
-- branch (return leg's first in-transit scan, after outbound already
-- delivered), and widen the return-leg completion branch's precondition to
-- also accept return_in_transit as a valid pre-state.
create or replace function public.apply_sendcloud_tracking_event(
  p_tracking_number text,
  p_carrier_code text,
  p_status_code text,
  p_status_description text,
  p_event_at timestamptz
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

  -- Return leg's own first in-transit scan, arriving after the outbound leg
  -- has already been delivered ("with employee"). New: previously nothing
  -- happened here at all.
  if v_normalized = 'in_transit' and v_leg = 'return' and v_order.fulfilment_status = 'delivered' then
    v_before := to_jsonb(v_order);

    v_log_entry := jsonb_build_object(
      'action', 'return_in_transit',
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
    set fulfilment_status = 'return_in_transit',
        return_courier = coalesce(return_courier, v_carrier_name),
        fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
    where id = v_order.id;

    perform public.log_audit(
      null, 'order.sendcloud_return_in_transit', 'orders', v_order.id, v_before,
      (select to_jsonb(o) from public.orders o where o.id = v_order.id)
    );

    return jsonb_build_object('matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', true, 'new_status', 'return_in_transit');
  end if;

  if v_normalized = 'delivered' then
    if v_order.service_type = 'ship_to_new_employee' then
      if v_order.fulfilment_status in ('dispatched', 'in_transit') then
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

        update public.orders
        set fulfilment_status = 'completed',
            confirmed_received_at = p_event_at,
            outbound_courier = coalesce(outbound_courier, v_carrier_name),
            fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
        where id = v_order.id;

        perform public.log_audit(
          null, 'order.sendcloud_delivered', 'orders', v_order.id, v_before,
          (select to_jsonb(o) from public.orders o where o.id = v_order.id)
        );

        return jsonb_build_object('matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', true, 'new_status', 'completed');
      end if;

    elsif v_leg = 'outbound' then
      if v_order.fulfilment_status in ('dispatched', 'in_transit') then
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

        update public.orders
        set fulfilment_status = 'delivered',
            outbound_courier = coalesce(outbound_courier, v_carrier_name),
            fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
        where id = v_order.id;

        perform public.log_audit(
          null, 'order.sendcloud_outbound_delivered', 'orders', v_order.id, v_before,
          (select to_jsonb(o) from public.orders o where o.id = v_order.id)
        );

        return jsonb_build_object('matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', true, 'new_status', 'delivered');
      end if;

    elsif v_leg = 'return' then
      if v_order.fulfilment_status in ('dispatched', 'in_transit', 'delivered', 'return_in_transit') then
        v_before := to_jsonb(v_order);

        v_log_entry := jsonb_build_object(
          'action', 'completed',
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
        set fulfilment_status = 'completed',
            return_courier = coalesce(return_courier, v_carrier_name),
            fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
        where id = v_order.id;

        perform public.log_audit(
          null, 'order.sendcloud_return_delivered', 'orders', v_order.id, v_before,
          (select to_jsonb(o) from public.orders o where o.id = v_order.id)
        );

        return jsonb_build_object('matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', true, 'new_status', 'completed');
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', false,
    'reason', 'no eligible transition from ' || v_order.fulfilment_status || ' for normalized status ' || v_normalized
  );
end;
$function$;

revoke all on function public.apply_sendcloud_tracking_event(text, text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_sendcloud_tracking_event(text, text, text, text, timestamptz) to service_role;

-- apply_sendcloud_poll_result(): mirror the same new branch + widened
-- precondition for the poll path.
create or replace function public.apply_sendcloud_poll_result(
  p_order_id uuid,
  p_actor_id uuid,
  p_tracking_number text,
  p_carrier_code text,
  p_parent_status text,
  p_status_description text,
  p_event_at timestamptz
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

  if v_normalized = 'in_transit' and v_leg = 'return' and v_order.fulfilment_status = 'delivered' then
    v_before := to_jsonb(v_order);

    v_log_entry := jsonb_build_object(
      'action', 'return_in_transit',
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
    set fulfilment_status = 'return_in_transit',
        return_courier = coalesce(return_courier, v_carrier_name),
        fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
    where id = v_order.id;

    perform public.log_audit(
      p_actor_id, 'order.poll_return_in_transit', 'orders', v_order.id, v_before,
      (select to_jsonb(o) from public.orders o where o.id = v_order.id)
    );

    return jsonb_build_object('matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', true, 'new_status', 'return_in_transit');
  end if;

  if v_normalized = 'delivered' then
    if v_order.service_type = 'ship_to_new_employee' then
      if v_order.fulfilment_status in ('dispatched', 'in_transit') then
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

        update public.orders
        set fulfilment_status = 'completed',
            confirmed_received_at = p_event_at,
            outbound_courier = coalesce(outbound_courier, v_carrier_name),
            fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
        where id = v_order.id;

        perform public.log_audit(
          p_actor_id, 'order.poll_delivered', 'orders', v_order.id, v_before,
          (select to_jsonb(o) from public.orders o where o.id = v_order.id)
        );

        return jsonb_build_object('matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', true, 'new_status', 'completed');
      end if;

    elsif v_leg = 'outbound' then
      if v_order.fulfilment_status in ('dispatched', 'in_transit') then
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

        update public.orders
        set fulfilment_status = 'delivered',
            outbound_courier = coalesce(outbound_courier, v_carrier_name),
            fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
        where id = v_order.id;

        perform public.log_audit(
          p_actor_id, 'order.poll_outbound_delivered', 'orders', v_order.id, v_before,
          (select to_jsonb(o) from public.orders o where o.id = v_order.id)
        );

        return jsonb_build_object('matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', true, 'new_status', 'delivered');
      end if;

    elsif v_leg = 'return' then
      if v_order.fulfilment_status in ('dispatched', 'in_transit', 'delivered', 'return_in_transit') then
        v_before := to_jsonb(v_order);

        v_log_entry := jsonb_build_object(
          'action', 'completed',
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
        set fulfilment_status = 'completed',
            return_courier = coalesce(return_courier, v_carrier_name),
            fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
        where id = v_order.id;

        perform public.log_audit(
          p_actor_id, 'order.poll_return_delivered', 'orders', v_order.id, v_before,
          (select to_jsonb(o) from public.orders o where o.id = v_order.id)
        );

        return jsonb_build_object('matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', true, 'new_status', 'completed');
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', false,
    'reason', 'no eligible transition from ' || v_order.fulfilment_status || ' for normalized status ' || v_normalized
  );
end;
$function$;

revoke all on function public.apply_sendcloud_poll_result(uuid, uuid, text, text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_sendcloud_poll_result(uuid, uuid, text, text, text, text, timestamptz) to service_role;

-- orders_needing_tracking_poll(): keep polling while return_in_transit, so
-- the eventual return-delivered event is still caught.
create or replace function public.orders_needing_tracking_poll()
returns table(order_id uuid, reference text, outbound_tracking_number text, return_tracking_number text)
language sql
stable
set search_path to 'public'
as $function$
  select o.id, o.reference, o.outbound_tracking_number, o.return_tracking_number
  from public.orders o
  where o.fulfilment_status in ('dispatched', 'in_transit', 'delivered', 'return_in_transit')
    and (
      o.outbound_tracking_number is not null
      or o.return_tracking_number is not null
      or exists (
        select 1 from public.order_tracking_numbers otn
        where otn.order_id = o.id and otn.status <> 'delivered'
      )
    );
$function$;

revoke all on function public.orders_needing_tracking_poll() from public, anon, authenticated;
grant execute on function public.orders_needing_tracking_poll() to service_role;

-- mark_return_completed(): staff can still manually close out an order
-- sitting at the new return_in_transit intermediate.
create or replace function public.mark_return_completed(p_order_id uuid, p_actor_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
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

  if v_order.fulfilment_status not in ('dispatched', 'in_transit', 'delivered', 'return_in_transit') then
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
$function$;

revoke all on function public.mark_return_completed(uuid, uuid) from public, anon, authenticated;
grant execute on function public.mark_return_completed(uuid, uuid) to service_role;

commit;
