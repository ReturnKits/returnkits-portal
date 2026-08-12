// supabase/functions/create-checkout-session/index.ts
//
// Hand-written per CLAUDE.md ("Money & concurrency ... hand-written, never
// generated"). Called by the Lovable checkout screen for a signed-in
// customer. Deployed with verify_jwt: true, so Supabase has already
// confirmed the bearer token is a real, current Supabase session before
// this code runs — but that alone says nothing about which orders the
// caller is allowed to pay for. That check is done by querying `orders`
// through a client built from the CALLER'S OWN JWT (not service_role), so
// the existing orders_select RLS policy — company_admin/company_member can
// see their own company's orders, nobody else's — is the one and only
// source of truth for "is this person allowed to pay this order". No
// company/role logic is duplicated here.
//
// This function only ever creates a Stripe Checkout Session and returns its
// URL. It never marks anything paid — that only happens in stripe-webhook,
// after Stripe itself confirms payment. If this function crashes, times
// out, or the customer just closes the tab, nothing in our database has
// changed: no order, invoice, or payment_status write happens here.
//
// Enhanced Cover (20260812): if an order has cover_tier_id set, it gets its
// own Stripe line item alongside the kit line -- never folded into the kit
// price -- so the invoice breakdown always shows kit and cover separately
// (architecture §20's worked example). Cover VAT comes from cover_tiers'
// own vat_rate column, same reasoning as kit_types.vat_rate: an
// accountant's ruling changes data, not code.
//
// Required secrets: STRIPE_SECRET_KEY (sk_test_... while in test mode).
// SUPABASE_URL / SUPABASE_ANON_KEY are provided automatically.

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
    "create-checkout-session: missing required env var(s) — check STRIPE_SECRET_KEY, " +
      "SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY",
  );
}

const stripe = new Stripe(stripeSecretKey ?? "", {
  apiVersion: "2024-12-18.acacia",
  httpClient: Stripe.createFetchHttpClient(),
});

type OrderRow = {
  id: string;
  company_id: string;
  price_ex_vat_pence: number;
  payment_status: string;
  cover_tier_id: string | null;
  cover_price_ex_vat_pence: number | null;
  kit_types: { label: string; vat_rate: string | number } | null;
  cover_tiers: { label: string; vat_rate: string | number } | null;
};

type StripeLineItem = {
  price_data: {
    currency: string;
    product_data: { name: string };
    unit_amount: number;
  };
  quantity: number;
};

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "create-checkout-session" });
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

  let body: { orderIds?: unknown; successUrl?: unknown; cancelUrl?: unknown };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const orderIds = Array.isArray(body.orderIds) ? body.orderIds.filter((id) => typeof id === "string") : [];
  const successUrl = typeof body.successUrl === "string" ? body.successUrl : null;
  const cancelUrl = typeof body.cancelUrl === "string" ? body.cancelUrl : null;

  if (orderIds.length === 0 || !successUrl || !cancelUrl) {
    return new Response(
      JSON.stringify({ error: "orderIds (non-empty array), successUrl, and cancelUrl are required" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // Caller-scoped client — every read below goes through this, so RLS (not
  // application code) decides which orders/company row this request can see.
  const userClient = createClient(supabaseUrl ?? "", anonKey ?? "", {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: orders, error: ordersError } = await userClient
    .from("orders")
    .select(
      "id, company_id, price_ex_vat_pence, payment_status, cover_tier_id, cover_price_ex_vat_pence, " +
        "kit_types(label, vat_rate), cover_tiers(label, vat_rate)",
    )
    .in("id", orderIds)
    .returns<OrderRow[]>();

  if (ordersError) {
    captureError(ordersError, { function: "create-checkout-session", step: "orders query" });
    return new Response(JSON.stringify({ error: "Could not look up orders" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // If RLS hid any requested order (wrong company, or it doesn't exist),
  // orders.length is short — refuse the whole request rather than silently
  // charging for a subset.
  if (!orders || orders.length !== orderIds.length) {
    return new Response(JSON.stringify({ error: "One or more orders were not found" }), {
      status: 404,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const companyId = orders[0].company_id;
  const sameCompany = orders.every((o) => o.company_id === companyId);
  const allPending = orders.every((o) => o.payment_status === "pending");

  if (!sameCompany) {
    return new Response(JSON.stringify({ error: "Orders must all belong to the same company" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  if (!allPending) {
    return new Response(JSON.stringify({ error: "One or more orders are not awaiting payment" }), {
      status: 409,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Integer pence throughout (CLAUDE.md rule 5). VAT computed per line and
  // summed, not computed once off the summed subtotal — keeps rounding
  // local to each line the way the invoice will ultimately show it. Cover
  // is deliberately its own line, never folded into the kit price/line —
  // architecture §20's worked example shows kit and cover as separate
  // invoice lines under one VAT total.
  let subtotalExVatPence = 0;
  let vatPence = 0;
  const lineItems: StripeLineItem[] = [];

  for (const order of orders) {
    const kitVatRate = Number(order.kit_types?.vat_rate ?? 0.2);
    const kitVatPence = Math.round(order.price_ex_vat_pence * kitVatRate);
    subtotalExVatPence += order.price_ex_vat_pence;
    vatPence += kitVatPence;
    lineItems.push({
      price_data: {
        currency: "gbp",
        product_data: { name: order.kit_types?.label ?? "ReturnKits kit" },
        // Stripe is charged the inc-VAT amount per line (architecture §20:
        // "charge the inc-VAT total, with VAT as a separate line so
        // Stripe's records match your invoices"); the ex-VAT/VAT split
        // itself is tracked in our own invoices table, not in Stripe.
        unit_amount: order.price_ex_vat_pence + kitVatPence,
      },
      quantity: 1,
    });

    if (order.cover_tier_id && order.cover_price_ex_vat_pence != null) {
      const coverVatRate = Number(order.cover_tiers?.vat_rate ?? 0.2);
      const coverVatPence = Math.round(order.cover_price_ex_vat_pence * coverVatRate);
      subtotalExVatPence += order.cover_price_ex_vat_pence;
      vatPence += coverVatPence;
      lineItems.push({
        price_data: {
          currency: "gbp",
          product_data: { name: order.cover_tiers?.label ?? "Enhanced Cover" },
          unit_amount: order.cover_price_ex_vat_pence + coverVatPence,
        },
        quantity: 1,
      });
    }
  }
  const totalIncVatPence = subtotalExVatPence + vatPence;

  // Look up (or create) a Stripe Customer for this company, so repeat
  // purchases and Stripe's own receipts/dashboard consolidate under one
  // customer rather than a fresh anonymous one each time. This is a cache
  // of an external id, not a money amount, so it's safe to backfill with a
  // service_role client regardless of whether the caller is company_admin
  // or company_member (only company_admin can UPDATE companies directly).
  const serviceClient = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");
  const { data: company, error: companyError } = await serviceClient
    .from("companies")
    .select("id, name, billing_email, stripe_customer_id")
    .eq("id", companyId)
    .single();

  if (companyError || !company) {
    captureError(companyError ?? new Error("company lookup returned no row"), {
      function: "create-checkout-session",
      step: "company lookup",
      companyId,
    });
    return new Response(JSON.stringify({ error: "Could not look up company" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  let stripeCustomerId = company.stripe_customer_id as string | null;
  if (!stripeCustomerId) {
    const customer = await stripe.customers.create({
      name: company.name,
      email: company.billing_email ?? undefined,
      metadata: { company_id: companyId },
    });
    stripeCustomerId = customer.id;
    await serviceClient.from("companies").update({ stripe_customer_id: stripeCustomerId }).eq("id", companyId);
  }

  const session = await stripe.checkout.sessions.create({
    mode: "payment",
    customer: stripeCustomerId,
    line_items: lineItems,
    success_url: successUrl,
    cancel_url: cancelUrl,
    // Read back verbatim by stripe-webhook and cross-checked against
    // session.amount_total before anything is written — see the "Defence
    // in depth" comment there.
    metadata: {
      type: "order_payment",
      company_id: companyId,
      order_ids: orderIds.join(","),
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
