// supabase/functions/sync-hubspot-signup/index.ts
//
// Hand-written per CLAUDE.md. Fires off an AFTER INSERT trigger on
// public.companies (trigger_sync_hubspot_signup(), see migration
// 20260904200000_hubspot_signup_sync.sql): syncs a new self-serve signup
// to HubSpot as a Contact + Company (linked), sets the Contact's Lead
// Status to "Sign-up" (a custom option added directly in the HubSpot
// portal, not via this codebase -- HubSpot property *schema* isn't
// reachable through the Private App token's own API surface for adding
// new dropdown options), and separately emails enquiries@returnkits.com
// so staff know a new customer signed up.
//
// Two independent side effects, two independent try/catches: a HubSpot
// failure must never block the internal notification email, and vice
// versa. Both are Sentry-captured; neither ever fails the trigger's own
// fire-and-forget net.http_post call back at the Postgres layer (this
// function always returns 200 with a per-step outcome in the body).
//
// Auth: same shared-service_role model as every other internal Edge
// Function in this project (send-order-email, generate-print-pack,
// poll-sendcloud-tracking) -- Authorization header must equal
// `Bearer <service_role key>` exactly. The trigger reads that key from
// Vault, never hardcoded in SQL.
//
// HubSpot credentials: NOT an Edge Function environment secret (unlike
// STRIPE_SECRET_KEY/RESEND_API_KEY) -- this project has no MCP tool for
// setting those, so the Private App access token is stored in Supabase
// Vault instead and read via the service_role-gated get_hubspot_credentials()
// RPC, mirroring get_sendcloud_api_credentials()'s exact shape.
//
// HubSpot API notes (researched via WebSearch before building, not
// assumed):
//   - Contact upsert: POST /crm/v3/objects/contacts/batch/upsert with
//     idProperty: "email" -- email is HubSpot's default unique Contact
//     identifier.
//   - Company upsert: POST /crm/v3/objects/companies/batch/upsert with
//     idProperty: "domain" is the documented default -- BUT this can fail
//     with "Unable to perform update/upsert by non-unique property domain"
//     if the portal already has duplicate domain values across existing
//     Company records. Handled below: on that specific error, fall back to
//     a plain POST /crm/v3/objects/companies create instead of failing the
//     whole sync.
//   - Association: PUT /crm/v4/objects/company/{companyId}/associations/
//     default/contact/{contactId} is the v4 "default association" endpoint
//     for the standard unlabeled Company<->Contact link.

import { createClient } from "jsr:@supabase/supabase-js@2";

// Inlined from ../_shared/sentry.ts, same reasoning as every other function
// in this project since 20260813: the deploy_edge_function MCP tool wasn't
// reliably bundling the cross-function shared import. Content identical to
// supabase/functions/_shared/sentry.ts.
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

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const resendApiKey = Deno.env.get("RESEND_API_KEY");
const FROM_ADDRESS = "ReturnKits <noreply@mail.returnkits.com>";
const ENQUIRIES_ADDRESS = "enquiries@returnkits.com";

if (!supabaseUrl || !serviceRoleKey || !resendApiKey) {
  console.error("sync-hubspot-signup: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / RESEND_API_KEY");
}

const supabase = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");

type CompanyRow = {
  id: string;
  name: string;
  domain: string | null;
  billing_email: string | null;
  created_at: string;
};

type AdminUserRow = {
  email: string;
  full_name: string | null;
};

async function hubspotFetch(accessToken: string, path: string, init: RequestInit): Promise<Response> {
  return fetch(`https://api.hubapi.com${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
}

type HubspotOutcome = { ok: true; contactId: string; companyId: string } | { ok: false; error: string };

async function syncToHubspot(company: CompanyRow, admin: AdminUserRow): Promise<HubspotOutcome> {
  const { data: creds, error: credsError } = await supabase.rpc("get_hubspot_credentials");
  if (credsError || !creds?.access_token) {
    return { ok: false, error: `get_hubspot_credentials failed: ${credsError?.message ?? "no access_token in Vault"}` };
  }
  const accessToken: string = creds.access_token;

  // 1. Contact upsert (idProperty: email).
  const contactResp = await hubspotFetch(accessToken, "/crm/v3/objects/contacts/batch/upsert", {
    method: "POST",
    body: JSON.stringify({
      inputs: [
        {
          idProperty: "email",
          id: admin.email,
          properties: {
            email: admin.email,
            ...(admin.full_name ? { firstname: admin.full_name.split(" ")[0], lastname: admin.full_name.split(" ").slice(1).join(" ") || admin.full_name } : {}),
            company: company.name,
            hs_lead_status: "Sign-up",
            lifecyclestage: "lead",
          },
        },
      ],
    }),
  });
  const contactBody = await contactResp.json().catch(() => ({}));
  if (!contactResp.ok) {
    return { ok: false, error: `Contact upsert failed (${contactResp.status}): ${JSON.stringify(contactBody).slice(0, 500)}` };
  }
  const contactId: string | undefined = contactBody?.results?.[0]?.id;
  if (!contactId) {
    return { ok: false, error: `Contact upsert returned no id: ${JSON.stringify(contactBody).slice(0, 500)}` };
  }

  // 2. Company upsert (idProperty: domain) -- with a fallback to a plain
  // create if the portal has a non-unique domain collision (a real,
  // documented HubSpot failure mode, not hypothetical).
  let companyId: string | undefined;
  if (company.domain) {
    const companyUpsertResp = await hubspotFetch(accessToken, "/crm/v3/objects/companies/batch/upsert", {
      method: "POST",
      body: JSON.stringify({
        inputs: [
          {
            idProperty: "domain",
            id: company.domain,
            properties: { name: company.name, domain: company.domain },
          },
        ],
      }),
    });
    const companyUpsertBody = await companyUpsertResp.json().catch(() => ({}));

    if (companyUpsertResp.ok) {
      companyId = companyUpsertBody?.results?.[0]?.id;
    } else {
      const bodyText = JSON.stringify(companyUpsertBody);
      const isNonUniqueDomain = bodyText.includes("non-unique property") || bodyText.includes("non-unique property domain");
      if (!isNonUniqueDomain) {
        return { ok: false, error: `Company upsert failed (${companyUpsertResp.status}): ${bodyText.slice(0, 500)}` };
      }
      // Fall through to plain create below.
    }
  }

  if (!companyId) {
    const createResp = await hubspotFetch(accessToken, "/crm/v3/objects/companies", {
      method: "POST",
      body: JSON.stringify({
        properties: { name: company.name, ...(company.domain ? { domain: company.domain } : {}) },
      }),
    });
    const createBody = await createResp.json().catch(() => ({}));
    if (!createResp.ok) {
      return { ok: false, error: `Company create failed (${createResp.status}): ${JSON.stringify(createBody).slice(0, 500)}` };
    }
    companyId = createBody?.id;
  }

  if (!companyId) {
    return { ok: false, error: "Company upsert/create returned no id" };
  }

  // 3. Associate Contact <-> Company (v4 default association).
  const assocResp = await hubspotFetch(
    accessToken,
    `/crm/v4/objects/company/${companyId}/associations/default/contact/${contactId}`,
    { method: "PUT" },
  );
  if (!assocResp.ok) {
    const assocBody = await assocResp.json().catch(() => ({}));
    return { ok: false, error: `Association failed (${assocResp.status}): ${JSON.stringify(assocBody).slice(0, 500)}` };
  }

  return { ok: true, contactId, companyId };
}

async function sendSignupNotification(
  company: CompanyRow,
  admin: AdminUserRow,
  hubspotOutcome: HubspotOutcome,
): Promise<void> {
  const hubspotLine = hubspotOutcome.ok
    ? `Synced to HubSpot (Contact ${hubspotOutcome.contactId}, Company ${hubspotOutcome.companyId})`
    : `HubSpot sync failed: ${hubspotOutcome.error}`;

  const html = `
    <div style="font-family: Arial, sans-serif; font-size: 14px; color: #1a1a1a; max-width: 560px;">
      <h2 style="margin: 0 0 16px;">New customer signed up</h2>
      <table cellpadding="6" cellspacing="0" style="border-collapse: collapse; width: 100%;">
        <tr><td style="color: #666;">Company</td><td><strong>${company.name}</strong></td></tr>
        <tr><td style="color: #666;">Domain</td><td>${company.domain ?? "—"}</td></tr>
        <tr><td style="color: #666;">Admin email</td><td>${admin.email}</td></tr>
        <tr><td style="color: #666;">Signed up</td><td>${new Date(company.created_at).toISOString()}</td></tr>
        <tr><td style="color: #666;">HubSpot</td><td>${hubspotLine}</td></tr>
      </table>
    </div>
  `;

  const resendResp = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: FROM_ADDRESS,
      to: ENQUIRIES_ADDRESS,
      subject: `New signup: ${company.name}`,
      html,
    }),
  });

  if (!resendResp.ok) {
    const resendBody = await resendResp.json().catch(() => ({}));
    throw new Error(`Resend send failed: ${JSON.stringify(resendBody).slice(0, 500)}`);
  }
}

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "sync-hubspot-signup" });
    return new Response(JSON.stringify({ error: "Internal error" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});

async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (authHeader !== `Bearer ${serviceRoleKey}`) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  let body: { companyId?: string };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), { status: 400 });
  }

  const companyId = body.companyId;
  if (!companyId || typeof companyId !== "string") {
    return new Response(JSON.stringify({ error: "companyId is required" }), { status: 400 });
  }

  const { data: company, error: companyError } = await supabase
    .from("companies")
    .select("id, name, domain, billing_email, created_at")
    .eq("id", companyId)
    .maybeSingle<CompanyRow>();

  if (companyError || !company) {
    captureError(companyError ?? new Error("company not found"), { function: "sync-hubspot-signup", companyId, step: "load company" });
    return new Response(JSON.stringify({ error: "Company not found" }), { status: 404 });
  }

  const { data: admin, error: adminError } = await supabase
    .from("users")
    .select("email, full_name")
    .eq("company_id", companyId)
    .eq("role", "company_admin")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle<AdminUserRow>();

  if (adminError || !admin) {
    captureError(adminError ?? new Error("admin user not found"), { function: "sync-hubspot-signup", companyId, step: "load admin" });
    return new Response(JSON.stringify({ error: "Admin user not found" }), { status: 404 });
  }

  let hubspotOutcome: HubspotOutcome;
  try {
    hubspotOutcome = await syncToHubspot(company, admin);
    if (!hubspotOutcome.ok) {
      captureError(new Error(hubspotOutcome.error), { function: "sync-hubspot-signup", companyId, step: "hubspot sync" });
    }
  } catch (err) {
    hubspotOutcome = { ok: false, error: err instanceof Error ? err.message : String(err) };
    captureError(err, { function: "sync-hubspot-signup", companyId, step: "hubspot sync (thrown)" });
  }

  try {
    await sendSignupNotification(company, admin, hubspotOutcome);
  } catch (err) {
    captureError(err, { function: "sync-hubspot-signup", companyId, step: "signup notification email" });
  }

  return new Response(JSON.stringify({ companyId, hubspotOutcome }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}
