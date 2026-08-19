// supabase/functions/cancel-pending-order/index.ts
//
// Hand-written per CLAUDE.md. Lets a signed-in customer cancel their own
// company's order while it's still unpaid, added 20260819 in direct
// response to: "when customers create an order, the order is created first
// then they can pay for it after, before they can pay, give them the
// option to cancel."
//
// Why this Edge Function exists at all, rather than a plain client-callable
// RPC: cancel_pending_order() must set orders.payment_status = 'cancelled',
// and a trigger on public.orders (enforce_orders_payment_fields_immutable_
// by_client) unconditionally rejects any change to payment_status/
// invoice_id unless auth.role() = 'service_role' -- a deliberate anti-
// tampering invariant that predates this feature and is not being loosened
// for it. This function is the thin, verified bridge: it authenticates the
// caller from their own JWT (exactly like create-checkout-session /
// create-credit-checkout-session / export-orders-email), then invokes
// cancel_pending_order via the service_role key, passing the caller's own
// user id as p_actor_id. All the real authorization logic (must be the
// order's creator, a company_admin, or internal staff; order must belong
// to the actor's own company; order must still be payment_status =
// 'pending' and fulfilment_status = 'awaiting_dispatch') lives in the RPC
// itself, not here -- this function only proves who is calling.
//
// See 20260819250000_fix_cancel_pending_order_service_role_pattern.sql for
// the full story of why the RPC ended up on this auth shape (a first
// attempt at a plain `authenticated`-callable RPC was live-tested and
// found to hit the trigger above on every call).
//
// Required secrets: SUPABASE_URL / SUPABASE_ANON_KEY /
// SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "jsr:@supabase/supabase-js@2";

// Inlined from ../_shared/sentry.ts -- same MCP-deploy bundling issue noted
// in every other Edge Function in this project (see e.g.
// export-orders-email's own header comment).
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
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!supabaseUrl || !anonKey || !serviceRoleKey) {
  console.error(
    "cancel-pending-order: missing required env var(s) — check SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY",
  );
}

type RequestBody = {
  orderId?: unknown;
  reason?: unknown;
};

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "cancel-pending-order" });
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

  const orderId = str(body.orderId);
  if (!orderId) {
    return new Response(JSON.stringify({ error: "orderId is required" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  const reason = str(body.reason);

  // Caller-scoped client — only used to prove who is calling. All real
  // authorization (creator/admin/company match, pending-only) happens
  // inside cancel_pending_order() itself.
  const userClient = createClient(supabaseUrl ?? "", anonKey ?? "", {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    captureError(userError ?? new Error("no user on caller JWT"), {
      function: "cancel-pending-order",
      step: "auth.getUser",
    });
    return new Response(JSON.stringify({ error: "Could not identify the calling user" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  const actorId = userData.user.id;

  const serviceClient = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");
  const { error: rpcError } = await serviceClient.rpc("cancel_pending_order", {
    p_order_id: orderId,
    p_actor_id: actorId,
    p_reason: reason,
  });

  if (rpcError) {
    // Not every rejection here is a bug (e.g. "already paid", "not your
    // order") — only report to Sentry, don't fail loudly on expected
    // business-rule rejections.
    return new Response(JSON.stringify({ error: rpcError.message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ cancelled: true }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
