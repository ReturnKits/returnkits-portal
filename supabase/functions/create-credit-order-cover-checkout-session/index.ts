// supabase/functions/create-credit-order-cover-checkout-session/index.ts
//
// Hand-written per CLAUDE.md ("Money & concurrency ... hand-written, never
// generated"). Called by the Lovable New Order form when a customer wants
// to pay for the kit with credit AND add Enhanced Cover on the same order
// (added 20260819, in direct response to a customer question: "why can't I
// add cover if I pay with credits?").
//
// This function only ever creates a Stripe Checkout Session for the cover
// amount and returns its URL — same non-negotiable rule as every other
// create-*-session function in this project. It never creates the order and
// never touches the credit ledger. That only happens in
// create_credit_order_with_paid_cover, called by stripe-webhook after
// Stripe confirms the cover payment. If this function crashes, times out,
// or the customer just closes the tab, nothing in our database has
// changed — no order, no spent credit.
//
// Company scoping works the same way as create-credit-checkout-session:
// querying `companies` through a client built from the CALLER'S OWN JWT
// (not service_role) returns exactly one row — the caller's own company —
// because companies_select RLS is "is_internal() OR id = current_company()".
//
// The credit balance check here is a courtesy, not the authoritative one —
// it exists purely so a customer with zero credits of this kit type never
// gets as far as paying for cover. The RPC re-checks the balance for real
// (with an advisory lock) at webhook time; see its own migration for the
// accepted edge case where the balance changes in between.
//
// Required secrets: STRIPE_SECRET_KEY. SUPABASE_URL / SUPABASE_ANON_KEY /
// SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import Stripe from "npm:stripe@17.5.0";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Inlined from ../_shared/sentry.ts — the deploy_edge_function MCP tool
// doesn't reliably bundle that cross-function relative import. Same fix
// already applied to send-order-email, generate-print-pack,
// export-orders-email, generate-invoice-pdf, sendcloud-webhook, and
// create-credit-checkout-session — see CLAUDE.md.
const SENTRY_DSN = Deno.env.get("SENTRY_DSN");

function parseDsn(dsn: string): { host: string; projectId: string; publicKey: string } | null {
  try {
    const url = new URL(dsn);
    const publicKey = url.username;
    const projectId = url.pathname.replace(/^\//, "");
    if (!publicKey || !projectId) return null;
    return { host: url.host, projectId, publicKey };
  } catch {
    return null;
  }
}

const sentryParsed = SENTRY_DSN ? parseDsn(SENTRY_DSN) : null;

function sentryEventId(): string {
  return crypto.randomUUID().replace(/-/g, "");
}

function captureError(
  err: unknown,
  context: { function: string; [key: string]: unknown } = { function: "unknown" },
): void {
  console.error(`[${context.function}]`, err);
  if (!sentryParsed) return;

  const error = err instanceof Error ? err : new Error(typeof err === "string" ? err : JSON.stringify(err));
  const { function: fnName, ...extra } = context;

  const event = {
    event_id: sentryEventId(),
    timestamp: new Date().toISOString(),
    platform: "other",
    level: "error",
    logger: "edge-function",
    server_name: fnName,
    environment: Deno.env.get("SENTRY_ENVIRONMENT") ?? "production",
    tags: { function: fnName },
    extra,
    exception: {
      values: [
        {
          type: error.name || "Error",
          value: error.message,
          stacktrace: error.stack
            ? { frames: error.stack.split("\n").map((line) => ({ filename: line.trim() })) }
            : undefined,
        },
      ],
    },
  };

  const endpoint = `https://${sentryParsed.host}/api/${sentryParsed.projectId}/store/`;

  fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Sentry-Auth": `Sentry sentry_version=7, sentry_key=${sentryParsed.publicKey}, sentry_client=returnkits-edge/1.0`,
    },
    body: JSON.stringify(event),
  }).catch((sentryErr) => {
    console.error(`[${fnName}] failed to report to Sentry:`, sentryErr);
  });
}

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
    "create-credit-order-cover-checkout-session: missing required env var(s) — check STRIPE_SECRET_KEY, " +
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

type KitTypeRow = { id: string; label: string; active: boolean };
type CoverTierRow = { id: string; label: string; price_ex_vat_pence: number; vat_rate: string | number; active: boolean };

type RequestBody = {
  kitTypeId?: unknown;
  serviceType?: unknown;
  coverTierId?: unknown;
  employeeId?: unknown;
  employeeName?: unknown;
  employeeEmail?: unknown;
  employeeAddressLine1?: unknown;
  employeeAddressLine2?: unknown;
  employeeCity?: unknown;
  employeePostcode?: unknown;
  employeeCountry?: unknown;
  returnAddressId?: unknown;
  deviceReference?: unknown;
  requestedSendDate?: unknown;
  leaverLastDay?: unknown;
  bundleId?: unknown;
  orderReference?: unknown;
  notifyEmployee?: unknown;
  successUrl?: unknown;
  cancelUrl?: unknown;
};

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "create-credit-order-cover-checkout-session" });
    return new Response(JSON.stringify({ error: "Internal error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

function str(v: unknown): string | null {
  return typeof v === "string" && v.trim().length > 0 ? v : null;
}

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

  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const kitTypeId = str(body.kitTypeId);
  const serviceType = str(body.serviceType);
  const coverTierId = str(body.coverTierId);
  const employeeId = str(body.employeeId);
  const employeeName = str(body.employeeName);
  const returnAddressId = str(body.returnAddressId);
  const successUrl = str(body.successUrl);
  const cancelUrl = str(body.cancelUrl);
  const notifyEmployee = body.notifyEmployee === true;

  if (!kitTypeId || !serviceType || !coverTierId || !successUrl || !cancelUrl) {
    return new Response(
      JSON.stringify({ error: "kitTypeId, serviceType, coverTierId, successUrl, and cancelUrl are required" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  if (serviceType !== "return" && serviceType !== "ship_to_new_employee") {
    return new Response(JSON.stringify({ error: "serviceType must be 'return' or 'ship_to_new_employee'" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (serviceType === "return" && !returnAddressId) {
    return new Response(JSON.stringify({ error: "returnAddressId is required for a return order" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if ((employeeId && employeeName) || (!employeeId && !employeeName)) {
    return new Response(
      JSON.stringify({ error: "Provide either employeeId or manual employee details, not both or neither" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // Caller-scoped client — RLS decides which company/kit-type/cover-tier/
  // employee/address rows this request can see.
  const userClient = createClient(supabaseUrl ?? "", anonKey ?? "", {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    captureError(userError ?? new Error("no user on caller JWT"), {
      function: "create-credit-order-cover-checkout-session",
      step: "auth.getUser",
    });
    return new Response(JSON.stringify({ error: "Could not identify the calling user" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  const createdBy = userData.user.id;

  const { data: company, error: companyError } = await userClient
    .from("companies")
    .select("id, name, billing_email, stripe_customer_id")
    .single();

  if (companyError || !company) {
    captureError(companyError ?? new Error("no company row visible to caller"), {
      function: "create-credit-order-cover-checkout-session",
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
    .select("id, label, active")
    .eq("id", kitTypeId)
    .maybeSingle();

  if (kitTypeError || !kitType || !(kitType as KitTypeRow).active) {
    captureError(kitTypeError ?? new Error("unknown/inactive kit type"), {
      function: "create-credit-order-cover-checkout-session",
      step: "kit type lookup",
    });
    return new Response(JSON.stringify({ error: "That kit type is not available" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  const kitTypeRow = kitType as KitTypeRow;

  const { data: coverTier, error: coverTierError } = await userClient
    .from("cover_tiers")
    .select("id, label, price_ex_vat_pence, vat_rate, active")
    .eq("id", coverTierId)
    .maybeSingle();

  if (coverTierError || !coverTier || !(coverTier as CoverTierRow).active) {
    captureError(coverTierError ?? new Error("unknown/inactive cover tier"), {
      function: "create-credit-order-cover-checkout-session",
      step: "cover tier lookup",
    });
    return new Response(JSON.stringify({ error: "That cover tier is not available" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  const coverTierRow = coverTier as CoverTierRow;

  if (coverTierRow.price_ex_vat_pence <= 0) {
    return new Response(JSON.stringify({ error: "That cover tier has no charge — nothing to pay separately for" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Courtesy balance check — see header comment. The RPC re-checks for real.
  const { data: ledgerRows, error: ledgerError } = await userClient
    .from("credit_ledger")
    .select("direction, quantity")
    .eq("company_id", companyRow.id)
    .eq("kit_type_id", kitTypeId);

  if (ledgerError) {
    captureError(ledgerError, { function: "create-credit-order-cover-checkout-session", step: "balance check" });
    return new Response(JSON.stringify({ error: "Could not check your credit balance" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  const balance = (ledgerRows ?? []).reduce(
    (sum, row) => sum + (row.direction === "credit" ? row.quantity : -row.quantity),
    0,
  );
  if (balance < 1) {
    return new Response(JSON.stringify({ error: `Insufficient ${kitTypeId} credit balance` }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (employeeId) {
    const { data: employee, error: employeeError } = await userClient
      .from("employees")
      .select("id")
      .eq("id", employeeId)
      .maybeSingle();
    if (employeeError || !employee) {
      return new Response(JSON.stringify({ error: "Employee not found for this company" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  }

  if (returnAddressId) {
    const { data: address, error: addressError } = await userClient
      .from("addresses")
      .select("id")
      .eq("id", returnAddressId)
      .maybeSingle();
    if (addressError || !address) {
      return new Response(JSON.stringify({ error: "Return address not found for this company" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  }

  const vatRate = Number(coverTierRow.vat_rate ?? 0);
  const subtotalExVatPence = coverTierRow.price_ex_vat_pence;
  const vatPence = Math.round(subtotalExVatPence * vatRate);
  const totalIncVatPence = subtotalExVatPence + vatPence;

  // Lazy-create-and-cache Stripe Customer — same pattern as
  // create-checkout-session / create-credit-checkout-session.
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
    customer: stripeCustomerId,
    line_items: [
      {
        price_data: {
          currency: "gbp",
          product_data: {
            name: `Enhanced Cover — ${coverTierRow.label} (${kitTypeRow.label} kit paid with credit)`,
          },
          unit_amount: totalIncVatPence,
        },
        quantity: 1,
      },
    ],
    success_url: successUrl,
    cancel_url: cancelUrl,
    metadata: {
      type: "credit_order_cover_payment",
      company_id: companyRow.id,
      created_by: createdBy,
      kit_type_id: kitTypeId,
      service_type: serviceType,
      cover_tier_id: coverTierId,
      cover_subtotal_ex_vat_pence: String(subtotalExVatPence),
      cover_vat_pence: String(vatPence),
      cover_total_inc_vat_pence: String(totalIncVatPence),
      employee_id: employeeId ?? "",
      employee_name: employeeName ?? "",
      employee_email: str(body.employeeEmail) ?? "",
      employee_address_line1: str(body.employeeAddressLine1) ?? "",
      employee_address_line2: str(body.employeeAddressLine2) ?? "",
      employee_city: str(body.employeeCity) ?? "",
      employee_postcode: str(body.employeePostcode) ?? "",
      employee_country: str(body.employeeCountry) ?? "",
      return_address_id: returnAddressId ?? "",
      device_reference: str(body.deviceReference) ?? "",
      requested_send_date: str(body.requestedSendDate) ?? "",
      leaver_last_day: str(body.leaverLastDay) ?? "",
      bundle_id: str(body.bundleId) ?? "",
      order_reference: str(body.orderReference) ?? "",
      notify_employee: notifyEmployee ? "1" : "0",
    },
  });

  return new Response(JSON.stringify({ url: session.url, sessionId: session.id }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
