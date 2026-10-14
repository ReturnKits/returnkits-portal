-- Backfilled from the hosted project (applied there directly via apply_migration)
-- so a local `db reset` reproduces hosted.
-- Adds two order-level columns surfacing information Sendcloud already
-- sends but that this project never promoted onto the order row:
--   orders.tracking_last_updated_at -- timestamp of the most recent
--     webhook/poll event this project successfully processed for the
--     order's PRIMARY tracking numbers (outbound_tracking_number /
--     return_tracking_number), regardless of whether that event caused a
--     fulfilment_status transition. Answers "is this tracking actually
--     current, or just stuck?" -- especially relevant given tracking here
--     is driven almost entirely by the hourly poll fallback, not a live
--     webhook (sendcloud_webhook_events has sat at zero rows in
--     production).
--   orders.estimated_delivery_date -- the carrier's own live delivery
--     estimate, confirmed present as a real top-level expected_delivery_date
--     field on genuine Sendcloud v2 tracking-poll responses (see the
--     20260814 return_in_transit entry). Previously this was only ever read
--     once, at email-send time, to compute a static estimate baked into
--     that one email; it was never stored, so the portal itself has no live
--     copy of it and can't show a value that updates as the estimate shifts.
--
-- Both are set by apply_sendcloud_tracking_event() (webhook path) and
-- apply_sendcloud_poll_result() (poll path) on every successful MATCH
-- against the order's own primary tracking numbers -- not gated on whether
-- a fulfilment_status transition actually applied, since "we heard from the
-- courier and here's the freshest estimate" is true even when the status
-- itself didn't move (e.g. a repeat scan, or an unmapped status code).
-- Extra-parcel matches (order_tracking_numbers rows) are deliberately left
-- out of this order-level bump -- an extra parcel's own status_log already
-- carries its own timestamps, and folding a secondary parcel's freshness
-- into the primary-leg columns would conflate two different signals.
--
-- Both functions gain one new trailing optional parameter,
-- p_expected_delivery_date date default null, populated by the Edge
-- Function passing through whatever value the real Sendcloud payload
-- happened to include (poll: confirmed present; webhook: read defensively,
-- never empirically confirmed on a real delivery since none have arrived).
-- Per this project's own hard-learned CREATE OR REPLACE FUNCTION lesson
-- (see 20260813160000 in CLAUDE.md), adding a parameter changes the
-- function's identity, so the old exact signature is dropped explicitly
-- before recreating -- otherwise a second overload would linger and
-- PostgREST/postgres would face the same PGRST203 ambiguity bug hit once
-- already on create_order/create_internal_order.

alter table public.orders
  add column tracking_last_updated_at timestamptz null,
  add column estimated_delivery_date date null;

comment on column public.orders.tracking_last_updated_at is
  'Timestamp of the most recent webhook/poll tracking event successfully matched against this order''s primary tracking numbers (outbound_tracking_number/return_tracking_number), regardless of whether it caused a fulfilment_status transition. Set by apply_sendcloud_tracking_event()/apply_sendcloud_poll_result(). Never set for extra-parcel (order_tracking_numbers) matches -- those carry their own status_log timestamps.';

comment on column public.orders.estimated_delivery_date is
  'Carrier''s own live delivery estimate (Sendcloud''s expected_delivery_date), overwritten on every fresh value received -- unlike courier/tracking-number columns this is expected to shift as the estimate updates. Populated by apply_sendcloud_tracking_event()/apply_sendcloud_poll_result(); null until the first tracking event carrying this field arrives.';

drop function if exists public.apply_sendcloud_poll_result(uuid, uuid, text, text, text, text, timestamptz);
drop function if exists public.apply_sendcloud_tracking_event(text, text, text, text, timestamptz);

create function public.apply_sendcloud_poll_result(
  p_order_id uuid,
  p_actor_id uuid,
  p_tracking_number text,
  p_carrier_code text,
  p_parent_status text,
  p_status_description text,
  p_event_at timestamptz,
  p_expected_delivery_date date default null
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

  -- Primary-leg match: bump the order-level freshness/estimate columns on
  -- every successful match, independent of whether a status transition
  -- ends up applying below.
  update public.orders
  set tracking_last_updated_at = greatest(coalesce(tracking_last_updated_at, p_event_at), p_event_at),
      estimated_delivery_date = coalesce(p_expected_delivery_date, estimated_delivery_date)
  where id = v_order.id;

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

create function public.apply_sendcloud_tracking_event(
  p_tracking_number text,
  p_carrier_code text,
  p_status_code text,
  p_status_description text,
  p_event_at timestamptz,
  p_expected_delivery_date date default null
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

  -- Primary-leg match: bump the order-level freshness/estimate columns on
  -- every successful match, independent of whether a status transition
  -- ends up applying below.
  update public.orders
  set tracking_last_updated_at = greatest(coalesce(tracking_last_updated_at, p_event_at), p_event_at),
      estimated_delivery_date = coalesce(p_expected_delivery_date, estimated_delivery_date)
  where id = v_order.id;

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

revoke all on function public.apply_sendcloud_poll_result(uuid, uuid, text, text, text, text, timestamptz, date) from public, anon, authenticated;
grant execute on function public.apply_sendcloud_poll_result(uuid, uuid, text, text, text, text, timestamptz, date) to postgres, service_role;

revoke all on function public.apply_sendcloud_tracking_event(text, text, text, text, timestamptz, date) from public, anon, authenticated;
grant execute on function public.apply_sendcloud_tracking_event(text, text, text, text, timestamptz, date) to postgres, service_role;
