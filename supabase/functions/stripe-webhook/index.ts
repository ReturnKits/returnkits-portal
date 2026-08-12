// supabase/functions/stripe-webhook/index.ts
//
// Hand-written per CLAUDE.md ("Money & concurrency ... hand-written, never
// generated"). This function has exactly two jobs:
//
//   1. Prove the request really came from Stripe (signature verification
//      against the raw request body — the one thing that MUST happen here
//      in Deno, since Postgres never sees the raw bytes/header Stripe signs).
//   2. Hand the verified event to the right Postgres RPC — a single RPC
//      call = a single transaction. All the "does this still add up" /
//      idempotency / atomicity logic lives there, not here.
//
// Three Checkout Session shapes reach this function, distinguished by
// metadata.type (set by whichever create-*-session function created the
// session — 20260812, credits system):
//
//   'order_payment'   (default/legacy — sessions created before this field
//                      existed have no metadata.type at all, so absence is
//                      treated the same as 'order_payment', never rejected)
//                      -> record_stripe_payment
//   'credit_purchase' -> record_credit_purchase
//   'card_setup'      -> record_card_setup, then set the card as the
//                        Stripe customer's default payment method so future
//                        Checkout Sessions (buying more credits) preselect it
//
// Deliberately NOT using verify_jwt (deployed with verify_jwt: false) —
// Stripe doesn't send a Supabase JWT, it sends its own signature. Trusting
// the Stripe-Signature header instead of Supabase auth here is correct,
// not a shortcut: this endpoint's entire security model is signature
// verification.
//
// Required secrets (set via `supabase secrets set`, never committed):
//   STRIPE_SECRET_KEY       — sk_test_... while in test mode (CLAUDE.md: stay
//                             in test mode until the launch gate)
//   STRIPE_WEBHOOK_SECRET   — whsec_... from the Stripe Dashboard webhook
//                             endpoint (or `stripe listen` for local testing)
// Supabase provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY to every Edge
// Function automatically — no need to set those by hand.

import Stripe from "npm:stripe@17.5.0";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { captureError } from "../_shared/sentry.ts";

const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!stripeSecretKey || !webhookSecret || !supabaseUrl || !serviceRoleKey) {
  console.error(
    "stripe-webhook: missing required env var(s) — check STRIPE_SECRET_KEY, " +
      "STRIPE_WEBHOOK_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY",
  );
}

const stripe = new Stripe(stripeSecretKey ?? "", {
  apiVersion: "2024-12-18.acacia",
  // Stripe's Node SDK defaults to node:crypto's synchronous HMAC, which
  // isn't available in Deno's runtime the same way — httpClient below plus
  // constructEventAsync() (used later) are the Deno-safe path.
  httpClient: Stripe.createFetchHttpClient(),
});

// service_role client: this is the ONE place in the whole app that's
// meant to call record_stripe_payment / record_credit_purchase /
// record_card_setup — see the lockdown migrations that revoke EXECUTE from
// anon/authenticated specifically because only this function's identity
// should ever reach them.
const supabase = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "stripe-webhook" });
    return new Response(JSON.stringify({ error: "Internal error" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});

async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const signature = req.headers.get("Stripe-Signature");
  if (!signature) {
    return new Response("Missing Stripe-Signature header", { status: 400 });
  }

  // Signature verification needs the exact raw bytes Stripe signed — never
  // parse this as JSON first, that would change whitespace/key order and
  // break the signature check.
  const rawBody = await req.text();

  let event: Stripe.Event;
  try {
    // constructEventAsync uses Web Crypto (available in Deno) rather than
    // node:crypto, which the synchronous constructEvent() needs.
    event = await stripe.webhooks.constructEventAsync(rawBody, signature, webhookSecret ?? "");
  } catch (err) {
    console.error("stripe-webhook: signature verification failed", err);
    // Exit criterion: "wrongly-signed webhook rejected." No DB write of any
    // kind happens above this line.
    return new Response(`Webhook signature verification failed: ${(err as Error).message}`, {
      status: 400,
    });
  }

  // Only checkout.session.completed carries the metadata this handler
  // needs (order_ids/kit_type_id/company_id, our own computed amounts) and
  // confirms payment (or setup, for card_setup) for Checkout's default
  // payment methods. Everything else is acknowledged (200) so Stripe stops
  // retrying, but changes nothing.
  if (event.type !== "checkout.session.completed") {
    return new Response(JSON.stringify({ received: true, ignored: event.type }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const session = event.data.object as Stripe.Checkout.Session;
  const metadata = session.metadata ?? {};
  // Absence of metadata.type means this session predates the credits system
  // (20260812) — treat exactly like 'order_payment', never reject a
  // legitimate legacy-shaped session just because the field is missing.
  const sessionType = metadata.type ?? "order_payment";

  switch (sessionType) {
    case "order_payment":
      return await handleOrderPayment(event, session, metadata);
    case "credit_purchase":
      return await handleCreditPurchase(event, session, metadata);
    case "card_setup":
      return await handleCardSetup(event, session, metadata);
    default:
      console.error("stripe-webhook: unrecognised metadata.type — refusing", {
        sessionId: session.id,
        sessionType,
      });
      return new Response(`Unrecognised session metadata.type: ${sessionType}`, { status: 400 });
  }
}

async function handleOrderPayment(
  event: Stripe.Event,
  session: Stripe.Checkout.Session,
  metadata: Record<string, string>,
): Promise<Response> {
  const companyId = metadata.company_id;
  const orderIdsRaw = metadata.order_ids;
  const subtotalExVatPence = Number(metadata.subtotal_ex_vat_pence);
  const vatPence = Number(metadata.vat_pence);
  const totalIncVatPence = Number(metadata.total_inc_vat_pence);

  if (
    !companyId ||
    !orderIdsRaw ||
    !Number.isFinite(subtotalExVatPence) ||
    !Number.isFinite(vatPence) ||
    !Number.isFinite(totalIncVatPence)
  ) {
    console.error("stripe-webhook: checkout.session.completed (order_payment) missing expected metadata", {
      sessionId: session.id,
      metadata,
    });
    // 400, not 200: this session wasn't created by create-checkout-session
    // (or something is badly wrong), so don't tell Stripe we handled it —
    // surface the failure instead of silently no-op'ing real money moving.
    return new Response("Missing or malformed session metadata", { status: 400 });
  }

  const orderIds = orderIdsRaw.split(",").filter(Boolean);

  // Defence in depth: the amount Stripe actually collected must match what
  // we told it to collect when the session was created. This catches any
  // scenario where metadata and the real charged amount have drifted
  // (line items were tampered with between creation and payment, a bug in
  // create-checkout-session, etc) — refuse rather than trust the metadata
  // blindly.
  if (session.amount_total !== totalIncVatPence) {
    console.error("stripe-webhook: amount_total does not match session metadata — refusing", {
      sessionId: session.id,
      amountTotal: session.amount_total,
      metadataTotal: totalIncVatPence,
    });
    return new Response("Amount mismatch between Stripe session and metadata", { status: 400 });
  }

  const { data: invoiceId, error } = await supabase.rpc("record_stripe_payment", {
    p_event_id: event.id,
    p_event_type: event.type,
    p_checkout_session_id: session.id,
    p_payment_intent_id: typeof session.payment_intent === "string" ? session.payment_intent : null,
    p_company_id: companyId,
    p_order_ids: orderIds,
    p_subtotal_ex_vat_pence: subtotalExVatPence,
    p_vat_pence: vatPence,
    p_total_inc_vat_pence: totalIncVatPence,
  });

  if (error) {
    captureError(new Error(`record_stripe_payment failed: ${error.message}`), {
      function: "stripe-webhook",
      sessionId: session.id,
      eventId: event.id,
    });
    // Non-2xx tells Stripe to retry — correct for a genuine failure (e.g.
    // the order set no longer matches). record_stripe_payment is a single
    // transaction, so nothing was left half-written.
    return new Response(`record_stripe_payment failed: ${error.message}`, { status: 500 });
  }

  // invoiceId is null exactly when this event_id had already been
  // processed (idempotent replay) — both cases are a success from Stripe's
  // point of view, so both return 200.
  return new Response(JSON.stringify({ received: true, invoiceId }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

async function handleCreditPurchase(
  event: Stripe.Event,
  session: Stripe.Checkout.Session,
  metadata: Record<string, string>,
): Promise<Response> {
  const companyId = metadata.company_id;
  const kitTypeId = metadata.kit_type_id;
  const quantity = Number(metadata.quantity);
  const subtotalExVatPence = Number(metadata.subtotal_ex_vat_pence);
  const vatPence = Number(metadata.vat_pence);
  const totalIncVatPence = Number(metadata.total_inc_vat_pence);

  if (
    !companyId ||
    !kitTypeId ||
    !Number.isInteger(quantity) ||
    quantity < 1 ||
    !Number.isFinite(subtotalExVatPence) ||
    !Number.isFinite(vatPence) ||
    !Number.isFinite(totalIncVatPence)
  ) {
    console.error("stripe-webhook: checkout.session.completed (credit_purchase) missing expected metadata", {
      sessionId: session.id,
      metadata,
    });
    return new Response("Missing or malformed session metadata", { status: 400 });
  }

  // Same defence in depth as order_payment — refuse rather than trust
  // metadata blindly if what Stripe actually collected doesn't match.
  if (session.amount_total !== totalIncVatPence) {
    console.error("stripe-webhook: amount_total does not match session metadata — refusing", {
      sessionId: session.id,
      amountTotal: session.amount_total,
      metadataTotal: totalIncVatPence,
    });
    return new Response("Amount mismatch between Stripe session and metadata", { status: 400 });
  }

  const { data: invoiceId, error } = await supabase.rpc("record_credit_purchase", {
    p_event_id: event.id,
    p_event_type: event.type,
    p_checkout_session_id: session.id,
    p_payment_intent_id: typeof session.payment_intent === "string" ? session.payment_intent : null,
    p_company_id: companyId,
    p_kit_type_id: kitTypeId,
    p_quantity: quantity,
    p_subtotal_ex_vat_pence: subtotalExVatPence,
    p_vat_pence: vatPence,
    p_total_inc_vat_pence: totalIncVatPence,
  });

  if (error) {
    captureError(new Error(`record_credit_purchase failed: ${error.message}`), {
      function: "stripe-webhook",
      sessionId: session.id,
      eventId: event.id,
    });
    return new Response(`record_credit_purchase failed: ${error.message}`, { status: 500 });
  }

  // invoiceId is null exactly when this event_id had already been
  // processed (idempotent replay) — both cases are a success from Stripe's
  // point of view.
  return new Response(JSON.stringify({ received: true, invoiceId }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

async function handleCardSetup(
  event: Stripe.Event,
  session: Stripe.Checkout.Session,
  metadata: Record<string, string>,
): Promise<Response> {
  const companyId = metadata.company_id;
  if (!companyId) {
    console.error("stripe-webhook: checkout.session.completed (card_setup) missing company_id metadata", {
      sessionId: session.id,
      metadata,
    });
    return new Response("Missing or malformed session metadata", { status: 400 });
  }

  const setupIntentId = typeof session.setup_intent === "string" ? session.setup_intent : session.setup_intent?.id;
  if (!setupIntentId) {
    console.error("stripe-webhook: card_setup session has no setup_intent", { sessionId: session.id });
    return new Response("Session has no setup_intent", { status: 400 });
  }

  // The session wasn't created with setup_intent expanded, so retrieve it
  // to get the PaymentMethod id that resulted from the customer entering
  // their card.
  const setupIntent = await stripe.setupIntents.retrieve(setupIntentId);
  const paymentMethodId =
    typeof setupIntent.payment_method === "string" ? setupIntent.payment_method : setupIntent.payment_method?.id;

  if (!paymentMethodId) {
    console.error("stripe-webhook: setup_intent has no resulting payment_method", {
      sessionId: session.id,
      setupIntentId,
    });
    return new Response("Setup intent has no resulting payment method", { status: 400 });
  }

  // record_card_setup is idempotent in effect (a plain UPDATE — replaying
  // the same event just writes the same value again), so no
  // stripe_webhook_events dedupe table entry is needed for this branch the
  // way record_stripe_payment/record_credit_purchase require it — there's
  // no ledger row or invoice this could double-write.
  const { error } = await supabase.rpc("record_card_setup", {
    p_company_id: companyId,
    p_stripe_payment_method_id: paymentMethodId,
  });

  if (error) {
    captureError(new Error(`record_card_setup failed: ${error.message}`), {
      function: "stripe-webhook",
      sessionId: session.id,
      eventId: event.id,
    });
    return new Response(`record_card_setup failed: ${error.message}`, { status: 500 });
  }

  // Set as the default payment method on the Stripe customer so future
  // Checkout Sessions (buying more credits) preselect it — this is what
  // actually makes "top up" feel one-click, not just the card being saved.
  const customerId = typeof session.customer === "string" ? session.customer : session.customer?.id;
  if (customerId) {
    await stripe.customers.update(customerId, {
      invoice_settings: { default_payment_method: paymentMethodId },
    });
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}
