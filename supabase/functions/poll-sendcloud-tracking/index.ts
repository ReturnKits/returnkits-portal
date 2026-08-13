// supabase/functions/poll-sendcloud-tracking/index.ts
//
// "Check Tracking Now" -- a manual, staff-triggered pull fallback for the
// push-based sendcloud-webhook path. See migration
// 20260813200000_sendcloud_poll_fallback.sql for the full reasoning: while
// confirming the webhook integration against a genuinely live order, we
// found sendcloud_webhook_events sits at zero rows -- no webhook has ever
// actually reached this system. This function lets staff ask Sendcloud
// directly, on demand, per order, independent of whatever's going on with
// the push side. Modelled on (not copied from) Base44's old
// pollSendcloudTracking button.
//
// Auth: Retool already holds the service_role key server-side (CLAUDE.md
// rule #2 / #7 -- "Retool holds its own privileged connection", "Retool
// writes call the app's API"). Every other Retool-triggered write in this
// project is a direct RPC call authenticated by auth.role() = 'service_role'
// inside Postgres. This function can't be a plain RPC (Postgres can't make
// outbound HTTP calls without pg_net, which this project hasn't adopted --
// every other external HTTP call so far is an Edge Function), so it
// reproduces the same trust boundary in Deno instead: verify_jwt is false
// (Retool isn't sending a Supabase user JWT), and the function checks the
// Authorization bearer against SUPABASE_SERVICE_ROLE_KEY itself before doing
// anything. Same threshold of trust as every RPC's auth.role() check, just
// enforced one layer up.
//
// Endpoint: Sendcloud v2 GET /tracking/{tracking_number} -- see the
// migration header for why v2 (not v3) was chosen. Basic Auth via
// get_sendcloud_api_credentials() (service_role-only RPC, Vault-backed).
//
// Live-tested 2026-08-13 via pg_net directly against Sendcloud's real API
// (a genuinely delivered Royal Mail parcel) before this went anywhere near
// Retool -- caught a real bug this way: the response's statuses[] array is
// NOT newest-first in practice, despite what the published OpenAPI example
// ordering implied. Fixed below to select by max carrier_update_timestamp
// instead of trusting array position.
//
// Sentry reporter inlined rather than imported from ../_shared/sentry.ts --
// same MCP-deploy bundling issue already hit and documented for
// send-order-email and generate-print-pack (Module not found on the
// cross-function relative import). Revisit the shared-module pattern if a
// future deploy needs it and the Supabase CLI is available instead of
// MCP-based deploys.

import { createClient } from "jsr:@supabase/supabase-js@2";

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

const parsedDsn = SENTRY_DSN ? parseDsn(SENTRY_DSN) : null;

function captureError(err: unknown, context: { function: string; [key: string]: unknown } = { function: "unknown" }): void {
  console.error(`[${context.function}]`, err);
  if (!parsedDsn) return;

  const error = err instanceof Error ? err : new Error(typeof err === "string" ? err : JSON.stringify(err));
  const { function: fnName, ...extra } = context;
  const event = {
    event_id: crypto.randomUUID().replace(/-/g, ""),
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
          stacktrace: error.stack ? { frames: error.stack.split("\n").map((line) => ({ filename: line.trim() })) } : undefined,
        },
      ],
    },
  };

  const endpoint = `https://${parsedDsn.host}/api/${parsedDsn.projectId}/store/`;
  fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Sentry-Auth": `Sentry sentry_version=7, sentry_key=${parsedDsn.publicKey}, sentry_client=returnkits-edge/1.0`,
    },
    body: JSON.stringify(event),
  }).catch((sentryErr) => console.error(`[${fnName}] failed to report to Sentry:`, sentryErr));
}

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!supabaseUrl || !serviceRoleKey) {
  console.error("poll-sendcloud-tracking: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
}

const supabase = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");

interface PollRequestBody {
  order_id?: string;
  actor_id?: string;
}

interface SendcloudTrackingStatus {
  carrier_update_timestamp: string;
  parcel_status_history_id: string;
  parent_status: string;
  carrier_code: string;
  carrier_message: string;
}

interface SendcloudTrackingBlob {
  parcel_id: string;
  carrier_code: string;
  statuses: SendcloudTrackingStatus[];
}

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "poll-sendcloud-tracking" });
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

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!serviceRoleKey || authHeader !== `Bearer ${serviceRoleKey}`) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  let body: PollRequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), { status: 400 });
  }

  const { order_id, actor_id } = body;
  if (!order_id || !actor_id) {
    return new Response(JSON.stringify({ error: "order_id and actor_id are both required" }), { status: 400 });
  }

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, reference, fulfilment_status, service_type, outbound_tracking_number, return_tracking_number")
    .eq("id", order_id)
    .single();

  if (orderError || !order) {
    return new Response(JSON.stringify({ error: "Order not found", detail: orderError?.message }), { status: 404 });
  }

  if (order.fulfilment_status === "completed" || order.fulfilment_status === "cancelled") {
    return new Response(
      JSON.stringify({ order_id, reference: order.reference, skipped: true, reason: `order is already ${order.fulfilment_status}` }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }

  const trackingNumbers = Array.from(
    new Set([order.outbound_tracking_number, order.return_tracking_number].filter((tn): tn is string => !!tn))
  );

  if (trackingNumbers.length === 0) {
    return new Response(
      JSON.stringify({ order_id, reference: order.reference, skipped: true, reason: "no tracking number on this order yet" }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }

  const { data: creds, error: credsError } = await supabase.rpc("get_sendcloud_api_credentials");
  if (credsError || !creds?.public_key || !creds?.secret_key) {
    captureError(credsError ?? new Error("poll-sendcloud-tracking: Sendcloud API credentials not available in Vault"), {
      function: "poll-sendcloud-tracking",
    });
    return new Response(JSON.stringify({ error: "Sendcloud API credentials not configured" }), { status: 500 });
  }

  const basicAuth = btoa(`${creds.public_key}:${creds.secret_key}`);
  const results: unknown[] = [];

  for (const trackingNumber of trackingNumbers) {
    try {
      const sendcloudRes = await fetch(`https://panel.sendcloud.sc/api/v2/tracking/${encodeURIComponent(trackingNumber)}`, {
        method: "GET",
        headers: { Authorization: `Basic ${basicAuth}` },
      });

      if (sendcloudRes.status === 404) {
        results.push({ tracking_number: trackingNumber, error: "not found in Sendcloud (404)" });
        continue;
      }
      if (sendcloudRes.status === 429) {
        results.push({ tracking_number: trackingNumber, error: "Sendcloud rate limit (429) -- try again shortly" });
        continue;
      }
      if (!sendcloudRes.ok) {
        results.push({ tracking_number: trackingNumber, error: `Sendcloud returned ${sendcloudRes.status}` });
        continue;
      }

      const blob: SendcloudTrackingBlob = await sendcloudRes.json();
      if (!blob.statuses || blob.statuses.length === 0) {
        results.push({ tracking_number: trackingNumber, error: "no status history yet" });
        continue;
      }

      // NOT newest-first: live-tested 2026-08-13 against a real delivered
      // parcel and found statuses[] is actually OLDEST-first in practice
      // (index 0 was "no-label" from days earlier, the "delivered" entries
      // were last) -- the opposite of what Sendcloud's own OpenAPI example
      // ordering suggested. Don't trust array position at all; pick by the
      // latest carrier_update_timestamp explicitly.
      const latest = blob.statuses.reduce((a, b) =>
        new Date(b.carrier_update_timestamp).getTime() > new Date(a.carrier_update_timestamp).getTime() ? b : a
      );

      const { data: applyResult, error: applyError } = await supabase.rpc("apply_sendcloud_poll_result", {
        p_order_id: order_id,
        p_actor_id: actor_id,
        p_tracking_number: trackingNumber,
        p_carrier_code: latest.carrier_code || blob.carrier_code,
        p_parent_status: latest.parent_status,
        p_status_description: latest.carrier_message || null,
        p_event_at: latest.carrier_update_timestamp,
      });

      if (applyError) {
        captureError(applyError, { function: "poll-sendcloud-tracking", trackingNumber, orderId: order_id });
        results.push({ tracking_number: trackingNumber, error: applyError.message });
        continue;
      }

      results.push({ tracking_number: trackingNumber, parent_status: latest.parent_status, ...applyResult });
    } catch (err) {
      captureError(err, { function: "poll-sendcloud-tracking", trackingNumber, orderId: order_id });
      results.push({ tracking_number: trackingNumber, error: err instanceof Error ? err.message : String(err) });
    }
  }

  return new Response(JSON.stringify({ order_id, reference: order.reference, results }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}
