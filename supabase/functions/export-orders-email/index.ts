// supabase/functions/export-orders-email/index.ts
//
// Hand-written per CLAUDE.md. Lets a signed-in company_admin email a CSV
// export of their company's orders to an address of their choice, from the
// My Orders screen. Added 20260818.
//
// Design decisions (confirmed with the user before building):
//   - Recipient is a free-text email address, no restriction to the
//     company's own domain or to existing Team members. `companies.domain`
//     is explicitly documented elsewhere in this codebase as unverified,
//     self-reported metadata that must never be used for an authorization
//     decision (two different companies have claimed the same domain
//     before) -- so it was never a candidate for gating the recipient here
//     either. The user explicitly chose "any email" over that option.
//   - Restricted to company_admin only -- checked here, not left to the
//     client, since the client is just React state a determined user could
//     bypass. The check queries the caller's OWN public.users row through a
//     client built from their OWN JWT (not service_role), so RLS -- not
//     application logic -- is what actually decides whether the row is
//     even visible, matching the pattern create-checkout-session already
//     established for "is this person allowed to see their own company's
//     data".
//   - The CSV content itself is built client-side in Lovable from whatever
//     rows are currently on screen (same data + same column shape as the
//     existing on-screen "Export CSV" button), then POSTed here as a
//     string. This function does not re-query or re-filter orders itself --
//     it only validates that the caller may send mail on behalf of their
//     company and relays the attachment. Whatever the admin can already see
//     and export to their own downloads folder, they can now also email;
//     no new data exposure is introduced.
//   - Not logged to communication_log: that table's `type` CHECK constraint
//     is scoped to order-lifecycle events tied to a single order_id
//     (order_confirmation/dispatched/checkin_sent/checkin_received/
//     return_in_transit) and this is a multi-order, ad-hoc admin action
//     with no natural order_id to attach to. Errors still go to Sentry.
//
// Required secrets: RESEND_API_KEY (already set for send-order-email --
// Edge Function secrets are project-wide, not per-function).
// SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are provided
// automatically.

import { createClient } from "jsr:@supabase/supabase-js@2";

// Inlined from ../_shared/sentry.ts -- same MCP-deploy bundling issue noted
// in send-order-email/generate-print-pack (cross-function relative imports
// weren't reliably bundled), so every function since has inlined this
// rather than risking a redeploy on it working.
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

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const resendApiKey = Deno.env.get("RESEND_API_KEY");
const FROM_ADDRESS = "ReturnKits <noreply@mail.returnkits.com>";

if (!supabaseUrl || !anonKey || !resendApiKey) {
  console.error("export-orders-email: missing SUPABASE_URL / SUPABASE_ANON_KEY / RESEND_API_KEY");
}

// Generous but bounded -- this is a relay for whatever's on screen, not an
// arbitrary file upload endpoint. A few thousand order rows is well under
// this; anything near it is more likely a mistake or abuse than a genuine
// export.
const MAX_CSV_BYTES = 2_000_000;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function utf8ToBase64(input: string): string {
  const bytes = new TextEncoder().encode(input);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "export-orders-email" });
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

  let body: { recipientEmail?: unknown; csvContent?: unknown; orderCount?: unknown };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const recipientEmail = typeof body.recipientEmail === "string" ? body.recipientEmail.trim() : "";
  const csvContent = typeof body.csvContent === "string" ? body.csvContent : "";
  const orderCount = typeof body.orderCount === "number" && Number.isFinite(body.orderCount) ? body.orderCount : null;

  if (!recipientEmail || !EMAIL_RE.test(recipientEmail)) {
    return new Response(JSON.stringify({ error: "A valid recipientEmail is required" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  if (!csvContent.trim()) {
    return new Response(JSON.stringify({ error: "csvContent must not be empty" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  if (new TextEncoder().encode(csvContent).length > MAX_CSV_BYTES) {
    return new Response(JSON.stringify({ error: "csvContent is too large" }), {
      status: 413,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Caller-scoped client -- RLS decides whether this row is even visible,
  // same trust boundary as create-checkout-session.
  const userClient = createClient(supabaseUrl ?? "", anonKey ?? "", {
    global: { headers: { Authorization: authHeader } },
  });

  const {
    data: { user },
    error: authError,
  } = await userClient.auth.getUser();

  if (authError || !user) {
    return new Response(JSON.stringify({ error: "Not authenticated" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const { data: profile, error: profileError } = await userClient
    .from("users")
    .select("role, company_id, full_name, email, companies(name)")
    .eq("id", user.id)
    .maybeSingle<{ role: string; company_id: string | null; full_name: string | null; email: string; companies: { name: string } | null }>();

  if (profileError) {
    captureError(profileError, { function: "export-orders-email", step: "profile lookup" });
    return new Response(JSON.stringify({ error: "Could not look up your account" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  if (!profile || !profile.company_id) {
    return new Response(JSON.stringify({ error: "Your account is not attached to a company" }), {
      status: 403,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  if (profile.role !== "company_admin") {
    return new Response(JSON.stringify({ error: "Only a company admin can email an orders export" }), {
      status: 403,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const companyName = profile.companies?.name ?? "your company";
  const senderName = profile.full_name || profile.email;
  const today = new Date().toISOString().slice(0, 10);
  const filename = `returnkits-orders-${today}.csv`;
  const countLine = orderCount != null ? `${orderCount} order${orderCount === 1 ? "" : "s"}` : "Orders";

  const html = `
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 480px; margin: 0 auto; padding: 32px 24px;">
      <p style="font-size: 18px; font-weight: 700; color: #2156C0; margin: 0 0 24px;">ReturnKits</p>
      <h2 style="font-size: 20px; font-weight: 600; color: #111827; margin: 0 0 12px;">Orders export from ${companyName}</h2>
      <p style="font-size: 14px; color: #4B5563; line-height: 1.5; margin: 0 0 12px;">
        ${senderName} shared a CSV export of ${countLine} from the ReturnKits portal. It's attached to this email as <strong>${filename}</strong>.
      </p>
      <p style="font-size: 13px; color: #9CA3AF; line-height: 1.5; margin: 0;">
        If you weren't expecting this, you can safely ignore it.
      </p>
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
      to: recipientEmail,
      subject: `Orders export from ${companyName}`,
      html,
      attachments: [{ filename, content: utf8ToBase64(csvContent) }],
    }),
  });

  const resendBody = await resendResp.json().catch(() => ({}));

  if (!resendResp.ok) {
    captureError(new Error(`Resend send failed: ${JSON.stringify(resendBody).slice(0, 500)}`), {
      function: "export-orders-email",
      companyId: profile.company_id,
    });
    return new Response(JSON.stringify({ error: "Resend send failed", detail: resendBody }), {
      status: 502,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ sent: true, messageId: resendBody.id ?? null }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
