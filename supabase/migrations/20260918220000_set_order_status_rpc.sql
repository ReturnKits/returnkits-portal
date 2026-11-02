-- Backfilled from the hosted project (applied there directly via apply_migration)
-- so a local `db reset` reproduces hosted.

-- Direct staff-facing status override, requested 20260918: "let me change order
-- statuses". Deliberately more permissive than the existing guarded actions
-- (mark_order_paid, mark_order_dispatched, cancel_order) -- those each enforce a
-- specific business precondition (e.g. can't dispatch unpaid, can't cancel once
-- dispatched); this RPC intentionally skips those preconditions so staff can
-- correct a mistake or handle an edge case those actions don't cover.
--
-- One guardrail kept anyway, not requested but load-bearing: 'cancelled' is
-- rejected for either status param. cancel_order's own cancellation path also
-- restores any credit spent on the order (see cancel_order's credit_ledger
-- 'adjustment' insert) -- a bare status flip here would silently skip that and
-- lose the customer's credit. Staff still cancel via the existing Cancel order
-- action; this RPC covers every other transition.
--
-- Real side effect worth knowing, not a bug: setting fulfilment_status to
-- 'dispatched' or payment_status to 'paid' fires the same AFTER UPDATE triggers
-- (on_order_dispatched_send_email / on_order_paid_send_confirmation) that the
-- guarded actions already fire today -- a real customer-facing email goes out.
-- Confirmed via pg_get_functiondef before writing this migration, not assumed.
--
-- Same hardened pattern as every other staff-only RPC in this codebase:
-- service_role-only + assert_internal_actor, audit_log entry, and a
-- fulfilment_log entry too (unlike mark_order_paid/archive_order, which only
-- log to audit_log) since this can move fulfilment_status, which is what
-- Lovable's customer-facing order-timeline.tsx renders from.
create or replace function public.set_order_status(
  p_order_id uuid,
  p_actor_id uuid,
  p_fulfilment_status text default null,
  p_payment_status text default null,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_order public.orders%rowtype;
  v_before jsonb;
  v_log_entry jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'set_order_status can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  if p_fulfilment_status is null and p_payment_status is null then
    raise exception 'set_order_status requires at least one of p_fulfilment_status or p_payment_status';
  end if;

  if p_fulfilment_status = 'cancelled' or p_payment_status = 'cancelled' then
    raise exception 'Use cancel_order to cancel an order -- it also restores any credit used. set_order_status deliberately does not support cancellation.';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  v_before := to_jsonb(v_order);

  v_log_entry := jsonb_build_object(
    'action', 'status_override',
    'actor_id', p_actor_id,
    'at', now(),
    'detail', jsonb_build_object(
      'reason', p_reason,
      'from_fulfilment_status', v_order.fulfilment_status,
      'to_fulfilment_status', coalesce(p_fulfilment_status, v_order.fulfilment_status),
      'from_payment_status', v_order.payment_status,
      'to_payment_status', coalesce(p_payment_status, v_order.payment_status)
    )
  );

  update public.orders
  set fulfilment_status = coalesce(p_fulfilment_status, fulfilment_status),
      payment_status = coalesce(p_payment_status, payment_status),
      fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
  where id = p_order_id;

  perform public.log_audit(
    p_actor_id, 'order.status_override', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;

revoke all on function public.set_order_status(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.set_order_status(uuid, uuid, text, text, text) to service_role;
