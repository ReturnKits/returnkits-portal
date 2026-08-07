-- ============================================================================
-- record_stripe_payment — the single, atomic write path the Stripe webhook
-- Edge Function calls once it has verified the event's signature. Everything
-- Stripe's webhook needs to do to our database happens in ONE plpgsql
-- function call, so it's ONE Postgres transaction: idempotency check,
-- invoice number, invoice row, and marking the orders paid either all
-- happen, or none do. This is deliberately mirrored on create_order() /
-- accept_invite() / create_company_and_admin() from Phases 1-2 — the same
-- "one SECURITY DEFINER function per money-or-identity-critical write path"
-- shape, for the same reason (Base44 audit §6: claimFreeKit marked itself
-- claimed before granting the credit, because it *couldn't* use a
-- transaction on that platform).
--
-- The Edge Function's own job is narrow on purpose: verify the Stripe
-- signature (must happen in Deno — Postgres has no access to the raw
-- request body/header Stripe signs), then call this function with the
-- event's data. All the "does this still add up" logic lives here in SQL,
-- where it's testable by the RLS/behaviour suite without needing a real
-- Stripe event.
-- ============================================================================

create or replace function public.record_stripe_payment(
  p_event_id text,
  p_event_type text,
  p_checkout_session_id text,
  p_payment_intent_id text,
  p_company_id uuid,
  p_order_ids uuid[],
  p_subtotal_ex_vat_pence integer,
  p_vat_pence integer,
  p_total_inc_vat_pence integer
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invoice_id uuid;
  v_invoice_number integer;
  v_matching_orders integer;
begin
  -- Idempotency, keyed on Stripe's own event id (architecture §9.7). First
  -- writer wins: ON CONFLICT DO NOTHING means a redelivered event inserts
  -- zero rows, which sets FOUND to false below, and we return early having
  -- changed nothing else. This is the exit-criteria test: "replaying the
  -- same webhook event twice changes nothing."
  insert into public.stripe_webhook_events (event_id, event_type)
  values (p_event_id, p_event_type)
  on conflict (event_id) do nothing;

  if not found then
    return null;
  end if;

  -- Defence in depth: re-check the orders against the database's own
  -- current state rather than trusting that nothing changed between
  -- checkout-session creation and webhook delivery (cancellation,
  -- concurrent payment, etc). If the set no longer matches exactly, refuse
  -- rather than silently marking a subset paid — this raises, which rolls
  -- back the stripe_webhook_events insert too, so Stripe's retry will hit
  -- the same check again rather than being silently swallowed.
  select count(*) into v_matching_orders
  from public.orders
  where id = any(p_order_ids)
    and company_id = p_company_id
    and payment_status = 'pending';

  if v_matching_orders is distinct from coalesce(array_length(p_order_ids, 1), 0) then
    raise exception
      'record_stripe_payment: order set no longer matches (expected % pending orders in company %, found %)',
      coalesce(array_length(p_order_ids, 1), 0), p_company_id, v_matching_orders;
  end if;

  -- Gapless, strictly sequential (UK VAT requirement, CLAUDE.md) — the one
  -- and only place invoice_number_seq is ever advanced.
  v_invoice_number := nextval('public.invoice_number_seq');

  insert into public.invoices (
    company_id, invoice_number, stripe_checkout_session_id, stripe_payment_intent_id,
    subtotal_ex_vat_pence, vat_pence, total_inc_vat_pence
  ) values (
    p_company_id, v_invoice_number, p_checkout_session_id, p_payment_intent_id,
    p_subtotal_ex_vat_pence, p_vat_pence, p_total_inc_vat_pence
  )
  returning id into v_invoice_id;

  -- Permitted despite trg_orders_payment_fields_immutable because this
  -- function is invoked by the webhook Edge Function using the
  -- service_role key -- auth.role() = 'service_role' for the duration of
  -- this call, which is exactly what that trigger allows through.
  update public.orders
  set payment_status = 'paid', invoice_id = v_invoice_id
  where id = any(p_order_ids);

  return v_invoice_id;
end;
$$;

-- Only the webhook handler (service_role) is meant to call this — same
-- revoke-from-public pattern as next_reference_number() and log_audit().
-- service_role already has EXECUTE by default in this project's Supabase
-- setup (nothing here explicitly grants it, matching the existing
-- convention for internal-only functions).
revoke all on function public.record_stripe_payment(
  text, text, text, text, uuid, uuid[], integer, integer, integer
) from public;
