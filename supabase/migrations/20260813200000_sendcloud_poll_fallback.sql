-- "Check Tracking Now" -- a manual, staff-triggered poll fallback,
-- mirroring Base44's old pollSendcloudTracking button (investigated for
-- domain knowledge, not copied -- see the 20260813 note on this same topic
-- lower in CLAUDE.md). Built in response to a real, live gap: while
-- confirming the tracking-webhook integration against a genuinely live
-- order (RKM-260809-001, real Royal Mail tracking MZ531042790GB), we found
-- sendcloud_webhook_events sits at zero rows -- no Sendcloud webhook has
-- ever been received by this system, for any order, despite the endpoint
-- being deployed and active. That's not proof the webhook path is broken,
-- but it means we currently have no way to know an order's real delivery
-- status if a webhook never arrives (dead endpoint, misconfigured
-- subscription, a delivery that happened before this system existed to
-- receive it, etc). A pull-based fallback closes that gap independent of
-- whatever's going on with the push side.
--
-- Deliberately a SEPARATE code path from apply_sendcloud_tracking_event(),
-- not a shared one, for a reason already flagged in this file: Sendcloud's
-- webhook payload and its GET /tracking/{number} poll endpoint are
-- different API surfaces with different status vocabularies. Confirmed
-- directly from source this time, not just suspected -- sendcloud-webhook's
-- own payload interface reads `events[].status_code` (e.g. matched against
-- sendcloud_status_map's status_code column: accepted, en_route,
-- out_for_delivery, delivered...), while Sendcloud's public v2 tracking-poll
-- OpenAPI spec (sendcloud.dev/api/v2/tracking/retrieve-tracking-information-of-a-parcel)
-- documents a totally different shape: `statuses[].parent_status`, with
-- example values `announcing`, `ready-to-send`, `shipment-on-route`,
-- `delivered` -- hyphenated, different words, not a rename of the webhook
-- vocabulary. Feeding poll results through sendcloud_status_map would
-- silently mismatch (only "delivered" happens to spell the same in both).
-- So: a new table, a new RPC, both scoped to the poll vocabulary, and the
-- existing webhook path is untouched.
--
-- Endpoint chosen deliberately: v2's GET /tracking/{tracking_number}, not
-- v3. Sendcloud's docs flag v2 as "entering maintenance mode" and steer new
-- integrations to v3, but v3's parcel-tracking surface found during
-- research (sendcloud.dev/api/v3/parcel-tracking/) is a POST endpoint for
-- *registering* an external parcel for tracking (useful for our
-- manually-bought-labels-elsewhere workflow in a different way, not what we
-- need here) still in beta, with no v3 GET-by-tracking-number status
-- endpoint found. v2's tracking GET is explicitly documented as "remains
-- fully functional" for existing integrations, and is the same surface
-- Base44's old pollSendcloudTracking already used successfully (per prior
-- investigation) -- the more conservative, already-proven choice for a
-- fallback whose whole point is reliability when the newer push path is in
-- question.
--
-- Values below are seeded from Sendcloud's own published v2 tracking
-- OpenAPI example, not guessed and not yet confirmed against a real poll
-- response from OUR account -- same "best-effort seed, extend from observed
-- traffic" discipline as sendcloud_status_map. `announcing`/`ready-to-send`
-- map to 'ignored': both represent pre-carrier-pickup states our own
-- fulfilment_status state machine has no separate slot for (we're already
-- at 'dispatched' by the time staff bother polling). No exception/RTS
-- equivalent is seeded -- add one only once actually observed.
create table public.sendcloud_poll_status_map (
  parent_status text primary key,
  normalized_status text not null,
  notes text
);

insert into public.sendcloud_poll_status_map (parent_status, normalized_status, notes) values
  ('announcing', 'ignored', 'Confirmed from Sendcloud v2 tracking API OpenAPI example -- pre-pickup, no fulfilment_status slot for this, not yet observed against a real poll response'),
  ('ready-to-send', 'ignored', 'Confirmed from Sendcloud v2 tracking API OpenAPI example -- pre-pickup, no fulfilment_status slot for this, not yet observed against a real poll response'),
  ('shipment-on-route', 'in_transit', 'Confirmed from Sendcloud v2 tracking API OpenAPI example, not yet observed against a real poll response'),
  ('delivered', 'delivered', 'Confirmed from Sendcloud v2 tracking API OpenAPI example, not yet observed against a real poll response');

alter table public.sendcloud_poll_status_map enable row level security;

-- Same default-deny shape as sendcloud_status_map / reference_counters --
-- service_role (this migration, and the Edge Function's admin client via
-- RPC) reads it, nobody else needs direct access.
revoke all on public.sendcloud_poll_status_map from public, anon, authenticated;

-- get_sendcloud_api_credentials(): the poll Edge Function needs Basic Auth
-- (public key as username, secret key as password) to call Sendcloud's API
-- as a client, distinct from get_sendcloud_webhook_secret() which only ever
-- returned the secret key alone (that function is scoped to HMAC
-- verification of inbound webhooks, a different use case with a narrower
-- return shape). Learned the hard way earlier today (20260813170000): a new
-- SECURITY DEFINER function needs BOTH an in-body auth.role() check AND an
-- explicit `revoke execute ... from anon, authenticated` -- `revoke all
-- from public` alone does not remove Supabase's default per-function grant
-- to those two roles. Both are present here from the start this time.
create or replace function public.get_sendcloud_api_credentials()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'vault'
as $function$
declare
  v_public_key text;
  v_secret_key text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'get_sendcloud_api_credentials can only be called by the poll-sendcloud-tracking Edge Function';
  end if;

  select decrypted_secret into v_public_key from vault.decrypted_secrets where name = 'sendcloud_public_key';
  select decrypted_secret into v_secret_key from vault.decrypted_secrets where name = 'sendcloud_secret_key';

  return jsonb_build_object('public_key', v_public_key, 'secret_key', v_secret_key);
end;
$function$;

revoke all on function public.get_sendcloud_api_credentials() from public;
revoke execute on function public.get_sendcloud_api_credentials() from anon, authenticated;

-- apply_sendcloud_poll_result: the poll-path counterpart to
-- apply_sendcloud_tracking_event(), same state-transition rules
-- (dispatched -> in_transit, {dispatched,in_transit} -> completed, same
-- ship_to_new_employee confirmed_received_at stamping), three deliberate
-- differences:
--   1. Looked up by p_order_id directly, not by scanning for a tracking
--      number match across all orders -- the caller (Retool, via the Edge
--      Function) already knows which order it's polling. p_tracking_number
--      is still passed and re-checked against the order's own columns
--      before anything is applied, so a stale poll (tracking number
--      corrected on the order between the outbound Sendcloud call and this
--      RPC running) is a no-op, not a wrong-order write.
--   2. actor_id is p_actor_id, never null -- this transition was triggered
--      by a specific staff member clicking a button, not inferred
--      automatically off a webhook. Kept distinct from the webhook path's
--      null-actor convention (documented elsewhere in this file for
--      confirmed_received_by) so anyone reading fulfilment_log later can
--      tell a human-triggered poll apart from a genuine push event.
--      confirmed_received_at itself is still stamped (same as the webhook
--      path) since the delivery evidence is still Sendcloud's tracking
--      data, not the staff member's own attestation -- confirmed_received_by
--      stays null either way, matching confirm_received's existing meaning
--      of that column (a specific person's own claim to have received it).
--   3. Looks up sendcloud_poll_status_map (parent_status), not
--      sendcloud_status_map (status_code) -- see the migration header.
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
  v_before jsonb;
  v_log_entry jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'apply_sendcloud_poll_result can only be called by the poll-sendcloud-tracking Edge Function';
  end if;

  perform public.assert_internal_actor(p_actor_id);

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
        'source', 'poll'
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
        'source', 'poll'
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
$function$;

revoke all on function public.apply_sendcloud_poll_result(uuid, uuid, text, text, text, text, timestamptz) from public;
revoke execute on function public.apply_sendcloud_poll_result(uuid, uuid, text, text, text, text, timestamptz) from anon, authenticated;
