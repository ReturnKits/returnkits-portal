-- Automatic hourly Sendcloud tracking polling -- the prerequisite the user
-- confirmed for "complete visibility about returns" as a selling point.
-- Without this, the new return_in_transit email (20260814150000) and Phase
-- 6 tracking generally only ever update off a genuine Sendcloud webhook
-- (sendcloud_webhook_events sits at zero rows in production, see
-- 20260813200000_sendcloud_poll_fallback.sql) or a staff member manually
-- clicking "Check Tracking Now" in Retool. This closes that gap the same
-- way the existing check-in nudges already work: a pg_cron job, hourly
-- (frequency confirmed with the user directly after asking about
-- resource/rate-limit risk -- Sendcloud's own published GET rate limit is
-- 1000 req/min, https://sendcloud.dev/docs/getting-started/rate-limits.md
-- -- hourly polling across this project's order volume is nowhere near
-- that ceiling).
--
-- Design decision this migration exists to resolve: apply_sendcloud_poll_result
-- was built exclusively for the human-triggered "Check Tracking Now" flow
-- and mandates a real internal staff p_actor_id (assert_internal_actor
-- raises if it doesn't resolve to an internal_admin/internal_ops user). A
-- pg_cron-triggered scheduled poll has no human behind it -- there is no
-- legitimate actor_id to supply. Two options were considered:
--   1. Create a fake "system" staff user row purely to satisfy the actor
--      check. Rejected: public.users.id has a hard FK to auth.users(id),
--      so this would mean provisioning a real auth account for a job that
--      isn't a person, and the audit trail would misleadingly show a named
--      "staff member" behind every scheduled poll.
--   2. Make p_actor_id NULLABLE-in-practice (Postgres function args already
--      accept NULL; the only blocker was assert_internal_actor's exists
--      check failing for null) and treat a null actor as "system-triggered",
--      exactly the convention apply_sendcloud_tracking_event's webhook path
--      already uses (actor_id is always literal `null` there, never a
--      placeholder user). Chosen -- it's the existing convention, not a new
--      one, and keeps the distinction between "a human clicked a button"
--      and "the system did this on schedule" visible directly in
--      fulfilment_log/audit_log rather than papered over by a fake actor.
--
-- The 'source' tag in each fulfilment_log entry's detail now distinguishes
-- three origins across this project's tracking paths: 'webhook' (implicit,
-- apply_sendcloud_tracking_event, always null actor), 'poll' (a human
-- clicked "Check Tracking Now", real actor_id), and the new
-- 'scheduled_poll' (pg_cron, null actor) -- so a "why did this order's
-- status change" question is always answerable from the log alone.

create or replace function public.apply_sendcloud_poll_result(p_order_id uuid, p_actor_id uuid, p_tracking_number text, p_carrier_code text, p_parent_status text, p_status_description text, p_event_at timestamp with time zone)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_order public.orders%rowtype;
  v_leg text;
  v_normalized text;
  v_before jsonb;
  v_log_entry jsonb;
  v_source text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'apply_sendcloud_poll_result can only be called by the poll-sendcloud-tracking Edge Function';
  end if;

  -- p_actor_id is null for the scheduled/hourly poll (pg_cron-triggered, no
  -- human involved) and non-null for a staff member clicking "Check
  -- Tracking Now" in Retool. Only validate when a human is actually
  -- claimed to be behind the call -- there is nothing to validate for a
  -- system-triggered run, same as the webhook path never validates an
  -- actor at all.
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
          fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
      where id = v_order.id;
    else
      update public.orders
      set fulfilment_status = 'completed',
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

-- Plain SQL, STABLE, no SECURITY DEFINER -- same shape as
-- orders_needing_checkin(), which this mirrors. This function is only ever
-- meant to be called by poll-sendcloud-tracking as service_role, so EXECUTE
-- is revoked from public/authenticated below, matching
-- orders_needing_checkin()'s own grants exactly (confirmed via
-- information_schema.routine_privileges before writing this comment, not
-- assumed) rather than relying on RLS-on-the-underlying-table as the only
-- line of defence.
create or replace function public.orders_needing_tracking_poll()
returns table(order_id uuid, reference text, outbound_tracking_number text, return_tracking_number text)
language sql
stable
set search_path to 'public'
as $$
  select id, reference, outbound_tracking_number, return_tracking_number
  from public.orders
  where fulfilment_status in ('dispatched', 'in_transit')
    and (outbound_tracking_number is not null or return_tracking_number is not null);
$$;

-- Same Vault-secret + pg_net.http_post pattern as trigger_checkin_notifications()
-- (20260809161000_phase5_email_triggers.sql) -- deliberately mirrored, not
-- reinvented.
create or replace function public.trigger_scheduled_tracking_poll()
returns void
language plpgsql
security definer
set search_path to 'public', 'vault', 'extensions'
as $$
declare
  v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'service_role_key';

  if v_key is null then
    raise warning 'trigger_scheduled_tracking_poll: service_role_key not found in Vault, skipping run';
    return;
  end if;

  perform net.http_post(
    url := 'https://pzewknoohcqdqrrhwqrs.supabase.co/functions/v1/poll-sendcloud-tracking',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body := '{}'::jsonb
  );
end;
$$;

-- Scheduled for 5 minutes past the hour, not on the hour -- the existing
-- checkin-notifications-hourly job already fires at :00; offsetting avoids
-- two unrelated pg_net-issuing cron jobs landing in the same second for no
-- reason other than tidiness (each is fire-and-forget async via pg_net, so
-- there's no real contention either way, but there's no reason to invite
-- log noise/confusion by stacking them).
select cron.schedule('sendcloud-tracking-poll-hourly', '5 * * * *', $$select public.trigger_scheduled_tracking_poll();$$);

revoke execute on function public.apply_sendcloud_poll_result(uuid, uuid, text, text, text, text, timestamp with time zone) from anon, authenticated;
revoke execute on function public.orders_needing_tracking_poll() from public, authenticated;
revoke execute on function public.trigger_scheduled_tracking_poll() from anon, authenticated;
