// supabase/functions/sendcloud-webhook/index.ts
//
// Hand-written per CLAUDE.md rule #4: every inbound webhook is
// signature-verified and idempotent, keyed on the provider's event ID.
// Sendcloud doesn't send Stripe/Resend-style discrete events with their own
// ID -- the payload is the full parcel object (tracking numbers + the
// complete events history to date), the same shape GET
// /parcels/tracking/{tracking_number} returns.
//
// Idempotency comes from apply_sendcloud_tracking_event() itself: it only
// transitions 'dispatched' -> 'in_transit', so calling it again for an
// event that already applied is a guaranteed no-op (the state guard fails
// the second time). sendcloud_webhook_events is a best-effort audit
// trail/dedup log recorded *after* a successful apply, not the mechanism
// that makes this safe -- so a crash between "applied" and "logged" just
// means a harmless duplicate log entry on the next retry, never a missed
// or double-applied transition.
//
// Signature: HMAC-SHA256 over the raw request body, HEX-encoded (not
// base64 -- Sendcloud's own PHP/Python doc examples both use
// hash_hmac(...)/.hexdigest(), unlike Resend's Svix base64 scheme), using
// the integration's Secret Key as the HMAC key, compared against the
// Sendcloud-Signature header. Verified 20260811 against a real "Test API
// Webhook" delivery from Sendcloud's dashboard -- signature check passed on
// the real thing, not just in theory.
//
// Scope note: this function only reacts to tracking *status* changes. It
// never purchases labels, validates addresses, or calls any Sendcloud
// write endpoint -- labels stay manual in Sendcloud's dashboard, per the
// user's explicit decision (20260811). Tracking-only half of Phase 6.
//
// The webhook secret is never a Deno env var -- it lives in Supabase Vault
// (get_sendcloud_webhook_secret()), same pattern as resend-webhook.
//
// Deliberately NOT using verify_jwt (deployed with verify_jwt: false) --
// Sendcloud doesn't send a Supabase JWT, it sends its own HMAC signature.
//
// return_in_transit email (added 20260814): when apply_sendcloud_tracking_event
// reports a transition to 'in_transit' on the *return* leg (leg === 'return',
// which the RPC only reports when p_tracking_number matched
// return_tracking_number -- ship_to_new_employee orders have no return leg
// per CLAUDE.md, so this can't misfire against the outbound leg), fire the
// customer-facing "Your return is on its way back" email via send-order-email,
// same fetch pattern send-checkin-notifications already uses to call it.
// estimatedArrivalDate is read defensively from the payload's top-level
// expected_delivery_date field, if present -- confirmed present on a real
// tracking-poll response (20260814) but NOT yet empirically confirmed on a
// real webhook payload specifically, since zero real webhooks have ever been
// received end-to-end (see the poll-fallback migration's own note). If
// absent, send-order-email falls back to its own working-day estimate.
// Non-blocking: an email failure here is captured to Sentry but never fails
// the webhook's own 200 ack to Sendcloud -- the tracking-state transition
// already succeeded and is the primary thing this webhook exists to record.
//
// Sentry reporter inlined rather than imported from ../_shared/sentry.ts, as
// part of this same 20260814 edit -- the deploy_edge_function MCP tool has
// repeatedly failed to bundle that cross-function relative import (Module
// not found) for send-order-email, generate-print-pack, and
// poll-sendcloud-tracking. This function was last deployed before that issue
// was diagnosed, so it was never proven to survive an MCP-based redeploy;
// inlined pre-emptively rather than risk it on this deploy too.

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
  console.error("sendcloud-webhook: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
}

const supabase = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");

// ---- signature verification ------------------------------------------

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// Not perfectly timing-safe in JS (same caveat as resend-webhook's
// safeEqual) -- meaningfully better than `===`, and the realistic attack
// surface (forging a valid HMAC without the secret) doesn't hinge on
// microsecond-level timing here.
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function verifySendcloudSignature(secret: string, rawBody: string, signatureHeader: string): Promise<boolean> {
  const keyBytes = new TextEncoder().encode(secret);
  const cryptoKey = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sigBytes = new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(rawBody)));
  const expected = bytesToHex(sigBytes);
  return safeEqual(expected.toLowerCase(), signatureHeader.toLowerCase());
}

// ---- payload shape (subset of the Parcel Tracking Response we use) ----

interface SendcloudEvent {
  event_at: string;
  event_type?: string;
  status_code: string;
  status_description?: string;
  status_type?: string;
  sub_status_code?: string;
}

interface SendcloudTrackingNumber {
  carrier_code: string;
  tracking_number: string;
}

interface SendcloudParcelPayload {
  tracking_numbers?: SendcloudTrackingNumber[];
  events?: SendcloudEvent[];
  // Top-level on a real v2 tracking-poll response (confirmed 20260814);
  // read defensively here since no real webhook delivery has been observed
  // yet to confirm the same field on this specific payload shape.
  expected_delivery_date?: string;
}

interface ApplyTrackingEventResult {
  matched: boolean;
  order_id?: string;
  leg?: "outbound" | "return";
  applied?: boolean;
  new_status?: string;
  reason?: string;
}

// Fires the customer-facing "return in progress" email once, off the
// courier's first scan on the return leg. Never throws -- a failure here is
// reported to Sentry but must never block the webhook's own ack.
async function triggerReturnInTransitEmail(orderId: string, estimatedArrivalDate: string | null): Promise<void> {
  try {
    const resp = await fetch(`${supabaseUrl}/functions/v1/send-order-email`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ orderId, type: "return_in_transit", estimatedArrivalDate }),
    });
    if (!resp.ok) {
      captureError(new Error(`send-order-email returned ${resp.status} for return_in_transit`), {
        function: "sendcloud-webhook",
        orderId,
        status: resp.status,
      });
    }
  } catch (err) {
    captureError(err, { function: "sendcloud-webhook", orderId, step: "trigger return_in_transit email" });
  }
}

// ---- Handler -------------------------------------------------------------

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "sendcloud-webhook" });
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

  const signatureHeader = req.headers.get("Sendcloud-Signature");
  if (!signatureHeader) {
    return new Response("Missing Sendcloud-Signature header", { status: 400 });
  }

  // Raw bytes matter -- verify against the exact string Sendcloud signed,
  // never a re-serialized JSON.parse(...) round-trip.
  const rawBody = await req.text();

  const { data: secret, error: secretError } = await supabase.rpc("get_sendcloud_webhook_secret");
  if (secretError || !secret) {
    captureError(secretError ?? new Error("sendcloud-webhook: signing secret not available in Vault"), {
      function: "sendcloud-webhook",
    });
    // 500, not 200 -- we cannot verify this request at all, so we must not
    // silently accept it. Sendcloud retries with backoff; once the secret
    // is set this starts working with no redeploy needed.
    return new Response("Webhook secret not configured", { status: 500 });
  }

  const valid = await verifySendcloudSignature(secret, rawBody, signatureHeader);
  if (!valid) {
    console.error("sendcloud-webhook: signature verification failed");
    return new Response("Invalid signature", { status: 400 });
  }

  let payload: SendcloudParcelPayload;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return new Response("Invalid JSON body", { status: 400 });
  }

  const trackingNumbers = payload.tracking_numbers ?? [];
  const events = payload.events ?? [];

  if (trackingNumbers.length === 0 || events.length === 0) {
    // Not a status update we act on (e.g. an announced_at/contract change
    // notification with no new tracking event) -- acknowledge, no-op.
    return new Response(JSON.stringify({ received: true, ignored: "no tracking_numbers/events" }), { status: 200 });
  }

  const results: unknown[] = [];

  for (const tn of trackingNumbers) {
    for (const evt of events) {
      // apply_sendcloud_tracking_event is the source of truth for
      // idempotency (state-guarded transition) -- safe to call for every
      // event in the payload's full history on every delivery, including
      // retries and events we've already applied.
      const { data: applyResult, error: applyError } = await supabase.rpc("apply_sendcloud_tracking_event", {
        p_tracking_number: tn.tracking_number,
        p_carrier_code: tn.carrier_code,
        p_status_code: evt.status_code,
        p_status_description: evt.status_description ?? null,
        p_event_at: evt.event_at,
      });

      if (applyError) {
        captureError(applyError, {
          function: "sendcloud-webhook",
          trackingNumber: tn.tracking_number,
          statusCode: evt.status_code,
        });
        continue;
      }

      results.push(applyResult);

      const typedResult = applyResult as ApplyTrackingEventResult;
      if (typedResult.applied && typedResult.new_status === "in_transit" && typedResult.leg === "return" && typedResult.order_id) {
        await triggerReturnInTransitEmail(typedResult.order_id, payload.expected_delivery_date ?? null);
      }

      // Best-effort audit/dedup log, recorded only after a successful
      // apply. Ignore unique-violation (23505) -- we've already logged
      // this exact event on a prior delivery of the same webhook.
      const { error: logError } = await supabase.from("sendcloud_webhook_events").insert({
        tracking_number: tn.tracking_number,
        status_code: evt.status_code,
        event_at: evt.event_at,
      });
      if (logError && logError.code !== "23505") {
        captureError(logError, { function: "sendcloud-webhook", trackingNumber: tn.tracking_number });
      }
    }
  }

  return new Response(JSON.stringify({ received: true, results }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}
