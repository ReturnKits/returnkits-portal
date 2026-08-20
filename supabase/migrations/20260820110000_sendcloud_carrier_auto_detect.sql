-- supabase/migrations/20260820110000_sendcloud_carrier_auto_detect.sql
--
-- Auto-populates orders.outbound_courier / return_courier from Sendcloud's
-- own carrier_code, instead of relying purely on a staff member typing the
-- courier name into Retool. Direct follow-on from a user question: "is
-- there a way to auto detect the courier by the tracking number?" -- the
-- honest answer is that regex-guessing a courier from a tracking number's
-- format is fragile (formats overlap and change), but this project doesn't
-- need to guess: both apply_sendcloud_poll_result() and
-- apply_sendcloud_tracking_event() already RECEIVE a carrier_code on every
-- call (Sendcloud tells us directly, since they generated the label) --
-- it was just being logged into fulfilment_log's detail blob and never
-- written back onto the order.
--
-- New table sendcloud_carrier_map (carrier_code -> display_name), same
-- shape/RLS/grant pattern as sendcloud_status_map / sendcloud_poll_status_map:
-- RLS enabled with zero policies (unreachable via anon/authenticated even
-- though PostgREST grants nothing to query it through), EXECUTE/SELECT
-- explicitly revoked from anon/authenticated (the fully hardened version --
-- sendcloud_poll_status_map already gets this, sendcloud_status_map
-- predates the lesson and was flagged but not retrofitted), managed by
-- migration only.
--
-- Seeded with exactly ONE confirmed value: 'royal_mailv2' -> 'Royal Mail'.
-- Confirmed by querying this project's own fulfilment_log history directly
-- (three real poll results -- RKL-260807-001, RKM-260809-001,
-- RKM-260809-002 -- all recorded carrier_code 'royal_mailv2' from real
-- Sendcloud API responses) rather than guessed. Same "best-effort seed,
-- extend only from observed traffic" convention already established for
-- sendcloud_status_map/sendcloud_poll_status_map -- no other carrier codes
-- (DPD, UPS, Evri, etc.) have ever been observed against this project's
-- Sendcloud account, so none are seeded speculatively. An unmapped
-- carrier_code simply leaves the courier column untouched (falls through
-- to the existing "your courier" / no-guidance-link fallback already in
-- send-order-email), never a wrong guess.
create table public.sendcloud_carrier_map (
  carrier_code text primary key,
  display_name text not null,
  created_at timestamptz not null default now()
);

alter table public.sendcloud_carrier_map enable row level security;

revoke all on public.sendcloud_carrier_map from public, anon, authenticated;
grant select, insert, update, delete on public.sendcloud_carrier_map to service_role;

insert into public.sendcloud_carrier_map (carrier_code, display_name) values
  ('royal_mailv2', 'Royal Mail');

-- Backfill behaviour: fills the relevant leg's courier column ONLY when it
-- is currently null -- never overwrites a value a staff member already
-- entered (whether typed manually or filled by an earlier tracking event).
-- Applied inside the SAME update statement that already runs for the
-- in_transit/delivered transitions in both functions -- no new write path,
-- same transaction, same audit-logged change. Accepted v1 simplification,
-- documented not engineered around (consistent with this project's own
-- established practice for such trade-offs): an order whose tracking never
-- reaches an eligible transition (e.g. every event is "unmapped" or a
-- repeat of the current status) never gets backfilled by this path -- in
-- practice this covers essentially every real shipment, since in_transit
-- or delivered fires at least once for any parcel that actually moves.
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
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_leg text;
  v_normalized text;
  v_carrier_name text;
  v_before jsonb;
  v_log_entry jsonb;
  v_source text;
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
    return jsonb_build_object(
      'matched', false, 'order_id', p_order_id,
      'reason', 'tracking number no longer matches this order -- stale poll result, not applied'
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
$$;

revoke execute on function public.apply_sendcloud_poll_result(uuid, uuid, text, text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_sendcloud_poll_result(uuid, uuid, text, text, text, text, timestamptz) to service_role;

-- Same treatment for the webhook path.
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
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_leg text;
  v_normalized text;
  v_carrier_name text;
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
$$;

revoke execute on function public.apply_sendcloud_tracking_event(text, text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_sendcloud_tracking_event(text, text, text, text, timestamptz) to service_role;
