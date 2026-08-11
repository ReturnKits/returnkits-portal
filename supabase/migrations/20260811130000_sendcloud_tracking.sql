-- ============================================================================
-- Phase 6 (narrow scope, per user decision 20260811): NOT label purchase
-- automation. Labels stay manual in Sendcloud's dashboard. This migration
-- adds only the piece the user asked for: tracking updates flowing into the
-- portal automatically via Sendcloud's parcel-status-changed webhook.
--
-- Feasibility note (researched this session): Sendcloud webhooks are scoped
-- to the *integration* a parcel belongs to, not to how the label was
-- created. A label bought manually in the dashboard still belongs to the
-- integration and still fires webhooks. The "return parcels only get
-- webhooks if the outgoing shipment was created through the API Shop"
-- caveat in Sendcloud's docs is read as referring to their own RMA/returns-
-- portal product (a consumer-initiated return tied to an API-created
-- order) -- ReturnKits doesn't use that feature; both legs are ordinary
-- parcels. To be confirmed empirically against the first live return order.
--
-- Three pieces:
--   1. get_sendcloud_webhook_secret() -- same Vault pattern as
--      get_resend_webhook_secret(). The Secret Key doubles as both the API
--      Basic Auth password and the HMAC-SHA256 webhook signing key
--      (confirmed in Sendcloud's docs).
--   2. sendcloud_status_map -- extensible normalization table. Sendcloud's
--      full status_code vocabulary isn't available as a static list (the
--      docs' own example only shows two codes, and the live API wasn't
--      reachable from this environment to enumerate the rest). Seeded with
--      the handful of codes we have real confidence in; the webhook
--      function logs any unrecognised status_code it sees rather than
--      guessing, so the map can be extended via a plain SQL insert -- no
--      redeploy -- once real payloads are observed.
--   3. 'in_transit' added to fulfilment_status -- the "courier actually has
--      it and it's moving" state the user asked for, automatically set by
--      apply_sendcloud_tracking_event() (companion migration), never by a
--      staff RPC. Both legs use the same status name per the earlier
--      decision (20260811, "Both legs need this").
--
-- confirm_received and mark_return_completed's state guards are widened
-- from "must be exactly 'dispatched'" to "'dispatched' or 'in_transit'" --
-- otherwise a real tracking scan landing before staff/customer close-out
-- would lock out the only two ways an order currently reaches 'completed'.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Vault-backed webhook secret getter
-- ----------------------------------------------------------------------------
create or replace function public.get_sendcloud_webhook_secret()
returns text
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'sendcloud_secret_key';
  return v_secret;
end;
$$;

revoke all on function public.get_sendcloud_webhook_secret() from public;
grant execute on function public.get_sendcloud_webhook_secret() to service_role;

-- ----------------------------------------------------------------------------
-- 2. Idempotency log -- Sendcloud's webhook payload is the full parcel
-- object, not a discrete event with its own ID (unlike Stripe/Resend), so
-- the dedupe key is a composite of tracking number + status code + the
-- event's own timestamp. First-insert-wins, same pattern as
-- resend_webhook_events.
-- ----------------------------------------------------------------------------
create table public.sendcloud_webhook_events (
  id uuid primary key default gen_random_uuid(),
  tracking_number text not null,
  status_code text not null,
  event_at timestamptz not null,
  received_at timestamptz not null default now(),
  unique (tracking_number, status_code, event_at)
);

alter table public.sendcloud_webhook_events enable row level security;
-- No policies: this table is only ever touched via service_role (the Edge
-- Function's client), which bypasses RLS entirely. No anon/authenticated
-- access is intended in either direction.

-- ----------------------------------------------------------------------------
-- 3. Status normalization map. normalized_status = 'in_transit' is the only
-- value currently acted on by apply_sendcloud_tracking_event(); other
-- normalized values are recorded for future use (e.g. a later 'delivered'
-- automation) but don't trigger a transition yet -- narrow scope, matching
-- what was actually asked for.
-- ----------------------------------------------------------------------------
create table public.sendcloud_status_map (
  status_code text primary key,
  normalized_status text not null check (normalized_status in ('in_transit', 'delivered', 'exception', 'ignored')),
  notes text
);

alter table public.sendcloud_status_map enable row level security;

-- Best-effort seed. 'accepted' is confirmed from Sendcloud's own v3 webhook
-- doc example (status_code: accepted, status_description: "Parcel has been
-- accepted by the carrier."). The rest are reasonable-confidence guesses at
-- Sendcloud's real vocabulary, not verified against a live payload --
-- extend this table once real events arrive. Unmapped codes are logged and
-- ignored, never guessed into a wrong transition.
insert into public.sendcloud_status_map (status_code, normalized_status, notes) values
  ('accepted', 'in_transit', 'Confirmed from Sendcloud v3 docs example'),
  ('en_route', 'in_transit', 'Unverified -- confirm against a real payload'),
  ('out_for_delivery', 'in_transit', 'Unverified -- confirm against a real payload'),
  ('at_sorting_center', 'in_transit', 'Unverified -- confirm against a real payload'),
  ('delivered', 'delivered', 'Recorded, not yet acted on -- close-out stays manual for now'),
  ('could_not_be_delivered', 'exception', 'Recorded, not yet acted on'),
  ('returned_to_sender', 'exception', 'Recorded, not yet acted on'),
  ('cancelled', 'ignored', 'Recorded, not yet acted on');

-- ----------------------------------------------------------------------------
-- 4. fulfilment_status: add 'in_transit' between 'dispatched' and the
-- close-out states.
-- ----------------------------------------------------------------------------
alter table public.orders drop constraint orders_fulfilment_status_check;
alter table public.orders add constraint orders_fulfilment_status_check
  check (fulfilment_status in ('awaiting_dispatch', 'dispatched', 'in_transit', 'delivered', 'confirmed_received', 'completed', 'cancelled'));

-- ----------------------------------------------------------------------------
-- 5. Widen confirm_received and mark_return_completed to accept 'in_transit'
-- as well as 'dispatched' -- a real tracking scan must not lock out the
-- existing manual close-out paths.
-- ----------------------------------------------------------------------------
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

  if v_order.fulfilment_status not in ('dispatched', 'in_transit') then
    raise exception 'Order is not awaiting a received confirmation (currently %)', v_order.fulfilment_status;
  end if;

  v_before := to_jsonb(v_order);

  v_log_entry := jsonb_build_object(
    'action', 'confirmed_received',
    'actor_id', auth.uid(),
    'at', now(),
    'detail', '{}'::jsonb
  );

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

create or replace function public.mark_return_completed(
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

  if v_order.fulfilment_status not in ('dispatched', 'in_transit') then
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
$$;

-- ----------------------------------------------------------------------------
-- 6. apply_sendcloud_tracking_event -- called once per verified, deduped
-- webhook delivery by the sendcloud-webhook Edge Function. service_role-only,
-- single transaction (mirrors record_stripe_payment's design).
--
-- Matches by tracking number against whichever leg is currently set on the
-- order (outbound_tracking_number for ship_to_new_employee/kit orders,
-- return_tracking_number for return orders) -- a flat order model has
-- exactly one active leg at a time, so no ambiguity.
--
-- Only transitions 'dispatched' -> 'in_transit'. Anything else (already
-- in_transit, already closed out, an unmapped status_code, a normalized
-- status we don't act on yet) is acknowledged as a no-op, never an error --
-- Sendcloud should never see a failure response for a webhook we simply
-- chose not to act on.
-- ----------------------------------------------------------------------------
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

  return jsonb_build_object(
    'matched', true, 'order_id', v_order.id, 'leg', v_leg, 'applied', false,
    'reason', 'no eligible transition from ' || v_order.fulfilment_status || ' for normalized status ' || v_normalized
  );
end;
$$;

revoke all on function public.apply_sendcloud_tracking_event(text, text, text, text, timestamptz) from public;
grant execute on function public.apply_sendcloud_tracking_event(text, text, text, text, timestamptz) to service_role;

comment on column public.orders.fulfilment_status is
  'awaiting_dispatch -> dispatched -> in_transit (automatic, Sendcloud webhook) -> completed/confirmed_received (manual close-out) | cancelled. in_transit added 20260811, set only by apply_sendcloud_tracking_event().';
