// supabase/functions/create-credit-checkout-session/index.ts
//
// Hand-written per CLAUDE.md ("Money & concurrency ... hand-written, never
// generated"). Called by the Lovable Credits page for a signed-in customer
// buying a block of prepaid credits for one kit type (20260812 -- prepaid
// credits, no bulk discount: same per-unit price as kit_types).
//
// Company scoping works the same way as create-checkout-session, just via
// a different row: querying `companies` through a client built from the
// CALLER'S OWN JWT (not service_role) returns exactly one row -- the
// caller's own company -- because companies_select RLS is
// "is_internal() OR id = current_company()", and this function is only
// ever called from the customer portal, never by internal staff. No
// company logic is duplicated here; RLS is the source of truth.
//
// This function only ever creates a Stripe Checkout Session and returns
// its URL. It never grants a credit -- that only happens in
// record_credit_purchase, called by stripe-webhook after Stripe itself
// confirms payment. If this function crashes, times out, or the customer
// just closes the tab, nothing in our database has changed.
//
// Required secrets: STRIPE_SECRET_KEY. SUPABASE_URL / SUPABASE_ANON_KEY
// are provided automatically.

import Stripe from "npm:stripe@17.5.0";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { captureError } from "../_shared/sentry.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!stripeSecretKey || !supabaseUrl || !anonKey || !serviceRoleKey) {
  console.error(
    "create-credit-checkout-session: missing required env var(s) — check STRIPE_SECRET_KEY, " +
      "SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY",
  );
}

const stripe = new Stripe(stripeSecretKey ?? "", {
  apiVersion: "2024-12-18.acacia",
  httpClient: Stripe.createFetchHttpClient(),
});

type CompanyRow = {
  id: string;
  name: string;
  billing_email: string | null;
  stripe_customer_id: string | null;
};

type KitTypeRow = {
  id: string;
  label: string;
  price_ex_vat_pence: number;
  vat_rate: string | number;
  active: boolean;
};

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "create-credit-checkout-session" });
    return new Response(JSON.stringify({ error: "Internal error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

async function handleRequest(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "Missing Authorization header" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  let body: { kitTypeId?: unknown; quantity?: unknown; successUrl?: unknown; cancelUrl?: unknown };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const kitTypeId = typeof body.kitTypeId === "string" ? body.kitTypeId : null;
  const quantity = typeof body.quantity === "number" ? Math.trunc(body.quantity) : NaN;
  const successUrl = typeof body.successUrl === "string" ? body.successUrl : null;
  const cancelUrl = typeof body.cancelUrl === "string" ? body.cancelUrl : null;

  if (!kitTypeId || !Number.isInteger(quantity) || quantity < 1 || quantity > 1000 || !successUrl || !cancelUrl) {
    return new Response(
      JSON.stringify({
        error: "kitTypeId, quantity (1-1000), successUrl, and cancelUrl are required",
      }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // Caller-scoped client — RLS decides which company row this request can see.
  const userClient = createClient(supabaseUrl ?? "", anonKey ?? "", {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: company, error: companyError } = await userClient
    .from("companies")
    .select("id, name, billing_email, stripe_customer_id")
    .single();

  if (companyError || !company) {
    captureError(companyError ?? new Error("no company row visible to caller"), {
      function: "create-credit-checkout-session",
      step: "company lookup",
    });
    return new Response(JSON.stringify({ error: "Could not determine your company" }), {
      status: 403,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  const companyRow = company as CompanyRow;

  const { data: kitType, error: kitTypeError } = await userClient
    .from("kit_types")
    .select("id, label, price_ex_vat_pence, vat_rate, active")
    .eq("id", kitTypeId)
    .maybeSingle();

  if (kitTypeError) {
    captureError(kitTypeError, { function: "create-credit-checkout-session", step: "kit type lookup" });
    return new Response(JSON.stringify({ error: "Could not look up kit type" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  const kitTypeRow = kitType as KitTypeRow | null;
  if (!kitTypeRow || !kitTypeRow.active || kitTypeRow.price_ex_vat_pence == null) {
    return new Response(JSON.stringify({ error: "That kit type is not available for credit purchase" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Same per-unit price as self-serve checkout — no bulk discount (v1 scope
  // decision, 20260812). Rounded per unit, then multiplied by quantity via
  // Stripe's own quantity field, matching how the invoice will read.
  const vatRate = Number(kitTypeRow.vat_rate ?? 0.2);
  const unitVatPence = Math.round(kitTypeRow.price_ex_vat_pence * vatRate);
  const unitIncVatPence = kitTypeRow.price_ex_vat_pence + unitVatPence;
  const subtotalExVatPence = kitTypeRow.price_ex_vat_pence * quantity;
  const vatPence = unitVatPence * quantity;
  const totalIncVatPence = subtotalExVatPence + vatPence;

  // Lazy-create-and-cache Stripe Customer — same pattern as
  // create-checkout-session, safe to backfill with service_role regardless
  // of caller's role since it's just an external id cache.
  const serviceClient = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");
  let stripeCustomerId = companyRow.stripe_customer_id;
  if (!stripeCustomerId) {
    const customer = await stripe.customers.create({
      name: companyRow.name,
      email: companyRow.billing_email ?? undefined,
      metadata: { company_id: companyRow.id },
    });
    stripeCustomerId = customer.id;
    await serviceClient.from("companies").update({ stripe_customer_id: stripeCustomerId }).eq("id", companyRow.id);
  }

  const session = await stripe.checkout.sessions.create({
    mode: "payment",
    // Passing the existing customer means Stripe Checkout automatically
    // offers a saved card (from create-card-setup-session) as a one-click
    // option — no embedded Elements or off-session charging needed.
    customer: stripeCustomerId,
    line_items: [
      {
        price_data: {
          currency: "gbp",
          product_data: { name: `${quantity} × ${kitTypeRow.label} credit${quantity === 1 ? "" : "s"}` },
          unit_amount: unitIncVatPence,
        },
        quantity,
      },
    ],
    success_url: successUrl,
    cancel_url: cancelUrl,
    metadata: {
      type: "credit_purchase",
      company_id: companyRow.id,
      kit_type_id: kitTypeId,
      quantity: String(quantity),
      subtotal_ex_vat_pence: String(subtotalExVatPence),
      vat_pence: String(vatPence),
      total_inc_vat_pence: String(totalIncVatPence),
    },
  });

  return new Response(JSON.stringify({ url: session.url, sessionId: session.id }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
