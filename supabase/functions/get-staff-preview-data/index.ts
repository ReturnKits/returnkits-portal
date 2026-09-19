// supabase/functions/get-staff-preview-data/index.ts
//
// Backs the staff preview link feature (see CLAUDE.md, 20260919): a single-
// purpose, unguessable, 1-hour-expiring token (staff_preview_tokens table +
// create_staff_preview_token RPC, migration 20260919105801) that lets staff
// view the ACTUAL Lovable portal read-only, exactly as one company's
// customer would see it, with no real Supabase Auth session ever created
// for that company. Direct follow-on from the earlier read-only Retool
// "View as" feature (20260919) -- that recreates the same data inside
// Retool's own UI; this backs a second, narrower mechanism that renders the
// data inside the ACTUAL portal's design.
//
// verify_jwt: false and reachable with NO Authorization header at all --
// possession of the token is the only credential. This is deliberately
// different from every other customer-facing Edge Function in this project
// (create-checkout-session, cancel-pending-order, etc.), which authenticate
// a real logged-in user's JWT -- there is no session here to authenticate.
//
// Returns everything the real portal's Orders / Order Detail / Invoices /
// Invoice Detail / Credits / Employees pages read via RLS-scoped
// supabase-js queries, gathered in one JSON payload via a service_role
// client explicitly scoped to token.company_id on every query -- the
// `.eq("company_id", companyId)` (or equivalent join) on each query below
// is what stands in for RLS, since a service_role connection bypasses it
// entirely.
//
// Read-only by construction: this function never writes to orders,
// invoices, credit_ledger, or employees -- the only write is stamping
// staff_preview_tokens.last_used_at, purely observational.

import { createClient } from "jsr:@supabase/supabase-js@2";

// Inlined Sentry reporter -- same pattern as send-order-email/
// generate-print-pack/sendcloud-webhook (the deploy_edge_function MCP tool
// wasn't reliably bundling a cross-function relative import to
// ../_shared/sentry.ts; inlining removes the risk rather than gambling on
// it working on this deploy).
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

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!supabaseUrl || !serviceRoleKey) {
  console.error("get-staff-preview-data: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
}

const supabase = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");

const ORDER_SELECT = `id, reference, order_reference, service_type, device_reference,
  price_ex_vat_pence, payment_status, paid_with_credit, invoice_id, fulfilment_status,
  cover_tier_id, cover_price_ex_vat_pence, cover_tiers(label, vat_rate),
  requested_send_date, leaver_last_day, created_at,
  kit_type_id, employee_id, employee_name, employee_email,
  employee_address_line1, employee_address_line2, employee_city,
  employee_postcode, employee_country, return_address_id, notify_employee,
  outbound_courier, outbound_tracking_number, outbound_tracking_url,
  return_courier, return_tracking_number, return_tracking_url,
  fulfilment_log, confirmed_sent_at, confirmed_received_at,
  kit_types(label, vat_rate),
  employees(full_name, email, phone),
  return_address:addresses!orders_return_address_id_fkey(label, address_line1, address_line2, city, postcode, country)`;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "get-staff-preview-data" });
    return json({ error: "Internal error" }, 500);
  }
});

async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  let body: { token?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const token = typeof body.token === "string" ? body.token.trim() : "";
  if (!token) {
    return json({ error: "token is required" }, 400);
  }

  const { data: tokenRow, error: tokenError } = await supabase
    .from("staff_preview_tokens")
    .select("id, company_id, expires_at, revoked_at")
    .eq("token", token)
    .maybeSingle();

  if (tokenError) {
    captureError(tokenError, { function: "get-staff-preview-data", step: "token lookup" });
    return json({ error: "Could not verify this preview link." }, 500);
  }

  if (!tokenRow) {
    return json({ error: "invalid_token", message: "This preview link is invalid." }, 404);
  }
  if (tokenRow.revoked_at) {
    return json({ error: "revoked_token", message: "This preview link has been revoked." }, 410);
  }
  if (new Date(tokenRow.expires_at).getTime() < Date.now()) {
    return json(
      { error: "expired_token", message: "This preview link has expired. Ask a member of staff to generate a new one." },
      410,
    );
  }

  // Observational only -- never blocks the response on failure.
  await supabase
    .from("staff_preview_tokens")
    .update({ last_used_at: new Date().toISOString() })
    .eq("id", tokenRow.id)
    .then(({ error }) => {
      if (error) captureError(error, { function: "get-staff-preview-data", step: "stamp last_used_at" });
    });

  const companyId = tokenRow.company_id as string;

  const [companyRes, ordersRes, employeesRes, invoicesRes, creditLedgerRes, kitTypesRes, enterpriseTiersRes, notifPrefRes] =
    await Promise.all([
      supabase
        .from("companies")
        .select("id, name, domain, enterprise_pricing_enabled")
        .eq("id", companyId)
        .maybeSingle(),
      supabase
        .from("orders")
        .select(ORDER_SELECT)
        .eq("company_id", companyId)
        .order("created_at", { ascending: false }),
      supabase.from("employees").select("*").eq("company_id", companyId).order("full_name"),
      supabase
        .from("invoices")
        .select(
          "id, invoice_number, issued_at, currency, subtotal_ex_vat_pence, vat_pence, total_inc_vat_pence, status, stripe_payment_intent_id",
        )
        .eq("company_id", companyId)
        .order("invoice_number", { ascending: false }),
      supabase
        .from("credit_ledger")
        .select("id, created_at, kit_type_id, transaction_type, direction, quantity, reason, invoice_id, order_id, kit_types(label)")
        .eq("company_id", companyId)
        .order("created_at", { ascending: false }),
      supabase.from("kit_types").select("id, label, price_ex_vat_pence").eq("active", true).eq("internal_only", false).order("label"),
      supabase
        .from("enterprise_pricing_tiers")
        .select("min_quantity, price_ex_vat_pence")
        .eq("kit_type_id", "laptop")
        .eq("active", true)
        .order("min_quantity"),
      supabase
        .from("notification_preferences")
        .select("enabled")
        .eq("company_id", companyId)
        .eq("event_type", "checkin_sent")
        .maybeSingle(),
    ]);

  for (const [label, res] of [
    ["company", companyRes],
    ["orders", ordersRes],
    ["employees", employeesRes],
    ["invoices", invoicesRes],
    ["credit_ledger", creditLedgerRes],
    ["kit_types", kitTypesRes],
    ["enterprise_pricing_tiers", enterpriseTiersRes],
  ] as const) {
    if (res.error) {
      captureError(res.error, { function: "get-staff-preview-data", step: `fetch ${label}`, companyId });
      return json({ error: `Could not load ${label} for this preview.` }, 500);
    }
  }

  const orders = (ordersRes.data ?? []) as Array<{ id: string; [key: string]: unknown }>;
  const orderIds = orders.map((o) => o.id);

  const [commsRes, parcelsRes] = orderIds.length
    ? await Promise.all([
        supabase
          .from("communication_log")
          .select("id, order_id, type, status, created_at")
          .in("order_id", orderIds)
          .eq("audience", "customer")
          .order("created_at", { ascending: true }),
        supabase
          .from("order_tracking_numbers")
          .select("id, order_id, leg, courier, tracking_number, tracking_url, status, status_log, created_at")
          .in("order_id", orderIds)
          .order("created_at", { ascending: true }),
      ])
    : [{ data: [], error: null }, { data: [], error: null }];

  if (commsRes.error) {
    captureError(commsRes.error, { function: "get-staff-preview-data", step: "fetch communication_log", companyId });
    return json({ error: "Could not load order updates for this preview." }, 500);
  }
  if (parcelsRes.error) {
    captureError(parcelsRes.error, { function: "get-staff-preview-data", step: "fetch order_tracking_numbers", companyId });
    return json({ error: "Could not load extra parcels for this preview." }, 500);
  }

  const commsByOrder = new Map<string, unknown[]>();
  for (const row of commsRes.data ?? []) {
    const list = commsByOrder.get(row.order_id as string) ?? [];
    list.push(row);
    commsByOrder.set(row.order_id as string, list);
  }

  const parcelsByOrder = new Map<string, unknown[]>();
  for (const row of parcelsRes.data ?? []) {
    const list = parcelsByOrder.get(row.order_id as string) ?? [];
    list.push(row);
    parcelsByOrder.set(row.order_id as string, list);
  }

  const ordersWithChildren = orders.map((o) => ({
    ...o,
    comms: commsByOrder.get(o.id) ?? [],
    extra_parcels: parcelsByOrder.get(o.id) ?? [],
  }));

  return json({
    company: companyRes.data,
    orders: ordersWithChildren,
    employees: employeesRes.data ?? [],
    invoices: invoicesRes.data ?? [],
    credit_ledger: creditLedgerRes.data ?? [],
    kit_types: kitTypesRes.data ?? [],
    enterprise_pricing_tiers: enterpriseTiersRes.data ?? [],
    checkin_reminders_enabled: notifPrefRes.data?.enabled ?? true,
    expires_at: tokenRow.expires_at,
  });
}
