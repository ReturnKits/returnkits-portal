// supabase/functions/resend-webhook/index.ts
//
// Hand-written per CLAUDE.md rule #4: every inbound webhook is
// signature-verified and idempotent, keyed on the provider's event ID.
// Resend signs webhooks via Svix (svix-id / svix-timestamp / svix-signature
// headers, HMAC-SHA256 over "svix-id.svix-timestamp.rawBody").
//
// Deliberately NOT using the svix or resend npm packages -- same
// crash-avoidance lesson as send-order-email's React Email removal this
// session: an npm import failing at Deno boot produces a bare 500 with no
// log line, which is much harder to debug than writing ~15 lines of Web
// Crypto ourselves. HMAC-SHA256 verification is short and has no
// dependencies beyond the Web Crypto API, which Deno's edge runtime
// supports natively.
//
// The webhook secret is never a Deno env var here -- it lives in Supabase
// Vault (get_resend_webhook_secret(), same pattern as
// trigger_send_order_email's service_role_key lookup) so it can be rotated
// via SQL without a redeploy.
//
// Two responsibilities:
//   1. communication_log.status tracking -- email.delivered / .bounced /
//      .complained flip the row that send-order-email created, matched by
//      Resend's own email_id (stored as provider_message_id).
//   2. Permanent suppression -- a hard bounce or spam complaint adds the
//      recipient to suppressed_recipients, which send-order-email checks
//      before every future send. This is the "Bounces recorded and
//      suppressed" Phase 5 exit criterion.
//
// Deliberately NOT using verify_jwt (deployed with verify_jwt: false) --
// Resend doesn't send a Supabase JWT, it sends its own Svix signature.

import { createClient } from "jsr:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!supabaseUrl || !serviceRoleKey) {
  console.error("resend-webhook: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
}

const supabase = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");

// ---- base64 helpers (Deno has no Node Buffer) ----------------------------

function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

// Constant-time-ish comparison -- not perfectly timing-safe in JS (string
// indexing/comparison isn't guaranteed constant time by the spec), but
// meaningfully better than `===` short-circuiting on first mismatch, and
// the realistic attack surface here (forging a valid HMAC without the
// secret) doesn't hinge on this microsecond-level timing anyway.
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function verifySvixSignature(params: {
  secret: string; // "whsec_<base64>"
  svixId: string;
  svixTimestamp: string;
  svixSignature: string; // space-separated "v1,<base64sig>" values
  rawBody: string;
}): Promise<boolean> {
  const { secret, svixId, svixTimestamp, svixSignature, rawBody } = params;

  // Reject stale/replayed timestamps (5 minute tolerance).
  const ts = Number(svixTimestamp);
  if (!Number.isFinite(ts) || Math.abs(Date.now() / 1000 - ts) > 300) {
    return false;
  }

  const secretB64 = secret.startsWith("whsec_") ? secret.slice("whsec_".length) : secret;
  const keyBytes = base64ToBytes(secretB64);
  const cryptoKey = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);

  const signedContent = `${svixId}.${svixTimestamp}.${rawBody}`;
  const sigBytes = new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(signedContent)));
  const expected = bytesToBase64(sigBytes);

  // svix-signature carries one or more "v1,<sig>" values (space-separated)
  // to support secret rotation -- valid if ANY of them match.
  const candidates = svixSignature.split(" ").map((v) => v.split(",")[1]).filter(Boolean);
  return candidates.some((candidate) => safeEqual(candidate, expected));
}

// ---- Handler ---------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const svixId = req.headers.get("svix-id");
  const svixTimestamp = req.headers.get("svix-timestamp");
  const svixSignature = req.headers.get("svix-signature");

  if (!svixId || !svixTimestamp || !svixSignature) {
    return new Response("Missing svix headers", { status: 400 });
  }

  // Raw bytes matter -- verify against the exact string Resend signed,
  // never a re-serialized JSON.parse(...) round-trip.
  const rawBody = await req.text();

  const { data: secret, error: secretError } = await supabase.rpc("get_resend_webhook_secret");
  if (secretError || !secret) {
    console.error("resend-webhook: signing secret not available in Vault", secretError);
    // 500, not 200 -- we cannot verify this request at all, so we must not
    // silently accept it. Resend retries with backoff; once the secret is
    // set this starts working with no redeploy needed.
    return new Response("Webhook secret not configured", { status: 500 });
  }

  const valid = await verifySvixSignature({ secret, svixId, svixTimestamp, svixSignature, rawBody });
  if (!valid) {
    console.error("resend-webhook: signature verification failed", { svixId });
    return new Response("Invalid signature", { status: 400 });
  }

  let event: { type?: string; data?: { email_id?: string; to?: string[] } };
  try {
    event = JSON.parse(rawBody);
  } catch {
    return new Response("Invalid JSON body", { status: 400 });
  }

  const eventType = event.type ?? "unknown";
  const emailId = event.data?.email_id ?? null;

  // Idempotency: Resend provides at-least-once delivery. svix-id is unique
  // per delivery attempt of a given event, so a first-insert-wins on that
  // key is the correct dedupe boundary (CLAUDE.md rule #4).
  const { error: insertError } = await supabase
    .from("resend_webhook_events")
    .insert({ event_id: svixId, event_type: eventType });

  if (insertError) {
    // Unique violation = we've already processed this exact delivery
    // attempt (a retry after our 200 got lost in transit, etc) -- ack and
    // do nothing further, not an error.
    if (insertError.code === "23505") {
      return new Response(JSON.stringify({ received: true, deduped: true }), { status: 200 });
    }
    console.error("resend-webhook: failed to record event", insertError);
    return new Response("Failed to record event", { status: 500 });
  }

  if (!emailId) {
    // domain.*/contact.* events we haven't subscribed to, or a malformed
    // payload -- acknowledge so Resend stops retrying, change nothing.
    return new Response(JSON.stringify({ received: true, ignored: eventType }), { status: 200 });
  }

  if (eventType === "email.delivered") {
    // Never downgrade a terminal negative state (bounced/complained) if
    // events arrive out of order.
    await supabase
      .from("communication_log")
      .update({ status: "delivered", updated_at: new Date().toISOString() })
      .eq("provider_message_id", emailId)
      .in("status", ["queued", "sent"]);
  } else if (eventType === "email.bounced" || eventType === "email.complained") {
    const status = eventType === "email.bounced" ? "bounced" : "complained";
    const reason = eventType === "email.bounced" ? "hard_bounce" : "complaint";

    const { data: logRow } = await supabase
      .from("communication_log")
      .update({ status, updated_at: new Date().toISOString() })
      .eq("provider_message_id", emailId)
      .select("id, recipient")
      .maybeSingle();

    const recipient = logRow?.recipient ?? event.data?.to?.[0];
    if (recipient) {
      // Permanent suppression -- checked by send-order-email before every
      // future send. on conflict do nothing: idempotent if the same
      // address bounces/complains more than once.
      await supabase
        .from("suppressed_recipients")
        .upsert(
          { email: recipient.toLowerCase(), reason, source_communication_log_id: logRow?.id ?? null },
          { onConflict: "email", ignoreDuplicates: true },
        );
    }
  }
  // email.sent / email.delivery_delayed / email.opened / email.clicked and
  // anything else: acknowledged, no state change needed for this schema.

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
