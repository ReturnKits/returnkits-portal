// supabase/functions/create-card-setup-session/index.ts
//
// Hand-written per CLAUDE.md ("Money & concurrency ... hand-written, never
// generated"). Called by the Lovable Credits page's "Save a card" button
// (20260812). Creates a Stripe Checkout Session in mode:'setup' — the same
// hosted-redirect pattern already used for orders and credit purchases,
// just collecting a card with no charge. No embedded Stripe Elements
// needed anywhere in the portal because of this.
//
// This function never touches card data itself and never charges anything
// — it only creates the session and returns its URL. The actual
// PaymentMethod id is captured by stripe-webhook -> record_card_setup once
// Stripe confirms the setup completed.
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
    "create-card-setup-session: missing required env var(s) — check STRIPE_SECRET_KEY, " +
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

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "create-card-setup-session" });
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

  let body: { successUrl?: unknown; cancelUrl?: unknown };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const successUrl = typeof body.successUrl === "string" ? body.successUrl : null;
  const cancelUrl = typeof body.cancelUrl === "string" ? body.cancelUrl : null;
  if (!successUrl || !cancelUrl) {
    return new Response(JSON.stringify({ error: "successUrl and cancelUrl are required" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const userClient = createClient(supabaseUrl ?? "", anonKey ?? "", {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: company, error: companyError } = await userClient
    .from("companies")
    .select("id, name, billing_email, stripe_customer_id")
    .single();

  if (companyError || !company) {
    captureError(companyError ?? new Error("no company row visible to caller"), {
      function: "create-card-setup-session",
      step: "company lookup",
    });
    return new Response(JSON.stringify({ error: "Could not determine your company" }), {
      status: 403,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  const companyRow = company as CompanyRow;

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
    mode: "setup",
    customer: stripeCustomerId,
    success_url: successUrl,
    cancel_url: cancelUrl,
    metadata: {
      type: "card_setup",
      company_id: companyRow.id,
    },
  });

  return new Response(JSON.stringify({ url: session.url, sessionId: session.id }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
