-- Bug: a return-type order was auto-completing the moment its OUTBOUND leg
-- (kit arriving at the employee) got a Sendcloud "delivered" scan, identical
-- to how a ship_to_new_employee order completes off its only leg. For a
-- return order that's wrong -- the device hasn't come back yet. Both
-- apply_sendcloud_tracking_event() (webhook) and apply_sendcloud_poll_result()
-- (poll/"Check tracking now") had the same bug: the 'delivered' branch never
-- looked at which leg (v_leg) matched for non-ship_to_new_employee orders.
--
-- Fix: for return orders, distinguish by leg.
--   outbound leg delivered -> fulfilment_status = 'delivered' (an existing,
--     previously-unused CHECK value) -- "kit is with the employee, return
--     still pending". Does NOT complete the order.
--   return leg delivered   -> fulfilment_status = 'completed', from any of
--     dispatched/in_transit/delivered -- the real completion signal.
-- ship_to_new_employee orders are completely unchanged: still complete
-- straight off their single outbound leg's delivered scan.
--
-- Companion fixes so the new intermediate state doesn't silently break
-- adjacent logic that only ever expected 'dispatched'/'in_transit':
--   orders_needing_checkin()      -- widened so the return-reminder nudge
--                                    keeps firing while an order sits at
--                                    'delivered' (kit is with the employee,
--                                    still hasn't been sent back) instead of
--                                    silently going quiet the moment tracking
--                                    moves the order past 'dispatched'.
--   orders_needing_tracking_poll() -- widened so polling continues at
--                                    'delivered', to catch the return leg's
--                                    own delivery scan.
--   mark_return_completed()        -- widened so staff can still manually
--                                    close out a return order sitting at
--                                    'delivered'.
-- confirm_received() is untouched -- ship_to_new_employee only, and that
-- service type never reaches 'delivered' via this fix.

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
set search_path = 'public'
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
      if v_order.fulfilment_status in ('dispatched', 'in_transit', 'delivered') then
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
set search_path = 'public'
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
      if v_order.fulfilment_status in ('dispatched', 'in_transit', 'delivered') then
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


-- Companion fix: keep the check-in reminder alive through the whole
-- "device hasn't come back yet" window, not just the literal 'dispatched'
-- value -- otherwise it silently stops nagging the moment tracking updates
-- the order (to 'in_transit', or now 'delivered').
create or replace function public.orders_needing_checkin()
returns table(order_id uuid, checkin_type text)
language sql
stable
set search_path = 'public'
as $function$
  with dispatched as (
    select
      o.id,
      o.return_method,
      o.collection_date,
      o.leaver_last_day,
      public.order_dispatched_at(o.id) as dispatched_at
    from public.orders o
    where o.fulfilment_status in ('dispatched', 'in_transit', 'delivered')
      and o.service_type = 'return'
  ),
  eligible_by_sla as (
    select
      id,
      'checkin_sent'::text as checkin_type
    from dispatched
    where dispatched_at is not null
      and (
        -- courier collection: gated on the scheduled collection date having
        -- passed (plus a one-day buffer), never on the dispatch-date SLA.
        (
          return_method = 'collection'
          and collection_date is not null
          and collection_date < (now() at time zone 'Europe/London')::date
        )
        or
        -- drop-off: existing 5-working-day SLA, but never before the
        -- leaver's own last day.
        (
          return_method = 'drop_off'
          and public.add_working_days(dispatched_at::date, 5) <= (now() at time zone 'Europe/London')::date
          and (leaver_last_day is null or leaver_last_day <= (now() at time zone 'Europe/London')::date)
        )
      )
  ),
  last_nudge as (
    select order_id, max(created_at) as last_sent_at
    from public.communication_log
    where type = 'checkin_sent'
      and status in ('sent', 'delivered')
    group by order_id
  )
  select e.id, e.checkin_type
  from eligible_by_sla e
  left join last_nudge n on n.order_id = e.id
  where n.last_sent_at is null or n.last_sent_at < now() - interval '3 days';
$function$;

revoke all on function public.orders_needing_checkin() from public, anon, authenticated;
grant execute on function public.orders_needing_checkin() to service_role;


-- Companion fix: keep polling an order once it's sitting at the new
-- intermediate 'delivered' state, so the return leg's own delivery scan
-- still gets detected and completes the order.
create or replace function public.orders_needing_tracking_poll()
returns table(order_id uuid, reference text, outbound_tracking_number text, return_tracking_number text)
language sql
stable
set search_path = 'public'
as $function$
  select o.id, o.reference, o.outbound_tracking_number, o.return_tracking_number
  from public.orders o
  where o.fulfilment_status in ('dispatched', 'in_transit', 'delivered')
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


-- Companion fix: staff must still be able to manually close out a return
-- order that's sitting at the new intermediate 'delivered' state.
create or replace function public.mark_return_completed(p_order_id uuid, p_actor_id uuid)
returns void
language plpgsql
security definer
set search_path = 'public'
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

  if v_order.fulfilment_status not in ('dispatched', 'in_transit', 'delivered') then
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
