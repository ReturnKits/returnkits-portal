-- Order cancellation (20260812): cancellation and other state transitions
-- were explicitly undesigned until credits/refund rules land (deferred per
-- CLAUDE.md) -- there was no RPC that could move an order into the
-- 'cancelled' state that the payment_status/fulfilment_status CHECK
-- constraints already allow. Needed now to correctly record a real test
-- order (RKP-260812-001) that was paid via live Stripe then refunded
-- directly in the Stripe dashboard, and to give staff a proper, audited way
-- to do this going forward rather than a one-off UPDATE.
--
-- Scope deliberately narrow, matching "don't build ahead" (CLAUDE.md build
-- order): no invoice voiding, no credit restoration -- credits (Phase 8)
-- don't exist yet. Only orders still 'awaiting_dispatch' can be cancelled;
-- anything already dispatched needs a real-world return, not a status flip.
--
-- Same auth pattern as every other staff-only RPC (mark_order_paid,
-- mark_order_dispatched, create_internal_order): service_role only
-- (Retool's write API), gated by assert_internal_actor(p_actor_id), logged
-- to audit_log via log_audit(), and appended to the order's own
-- fulfilment_log so the history is visible on the order itself too.

alter table public.orders
  add column if not exists cancel_reason text;

create or replace function public.cancel_order(
  p_order_id uuid,
  p_actor_id uuid,
  p_reason text default null
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
    raise exception 'cancel_order can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if v_order.fulfilment_status <> 'awaiting_dispatch' then
    raise exception 'Order % cannot be cancelled (fulfilment_status: %) -- only orders still awaiting dispatch can be cancelled', p_order_id, v_order.fulfilment_status;
  end if;

  v_before := to_jsonb(v_order);

  v_log_entry := jsonb_build_object(
    'action', 'cancelled',
    'actor_id', p_actor_id,
    'at', now(),
    'detail', jsonb_build_object('reason', p_reason, 'was_paid', v_order.payment_status = 'paid')
  );

  update public.orders
  set fulfilment_status = 'cancelled',
      payment_status = 'cancelled',
      cancel_reason = p_reason,
      fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
  where id = p_order_id;

  perform public.log_audit(
    p_actor_id, 'order.cancel', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;

-- Only the Retool write API (service_role) is meant to call this -- same
-- revoke-from-public pattern as mark_order_paid, next_reference_number(),
-- and log_audit().
revoke all on function public.cancel_order(uuid, uuid, text) from public;
revoke execute on function public.cancel_order(uuid, uuid, text) from anon, authenticated;
