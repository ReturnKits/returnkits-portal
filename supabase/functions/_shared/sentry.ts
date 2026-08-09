// supabase/functions/_shared/sentry.ts
//
// Hand-written. Deliberately not the @sentry/deno SDK -- this codebase's
// established pattern (see send-order-email, resend-webhook) is to avoid
// npm/jsr SDKs that can crash the Deno edge runtime at boot, and hand-roll
// the handful of HTTP calls actually needed instead.
//
// Sentry's ingestion "store" endpoint just wants a JSON POST with the DSN's
// public key in an auth header -- no SDK required. This posts one event per
// call; callers are expected to catch their own errors and call this from
// the catch block (fire-and-forget, never throws itself, never blocks the
// function's real response).
//
// Setup: `supabase secrets set SENTRY_DSN=<dsn> --project-ref <ref>`. If the
// secret isn't set, captureError() silently no-ops (logs to console only) --
// missing observability should never turn into a second failure mode.

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

const parsed = SENTRY_DSN ? parseDsn(SENTRY_DSN) : null;

function eventId(): string {
  // Sentry wants a 32-char hex event ID with no dashes.
  return crypto.randomUUID().replace(/-/g, "");
}

/**
 * Reports an error to Sentry. Fire-and-forget -- never throws, never awaits
 * the network call to completion on the caller's critical path (the
 * function's real response should not wait on Sentry being up).
 *
 * @param err     The caught error (or any thrown value).
 * @param context Free-form tags/extra to help triage -- at minimum pass
 *                { function: "<edge-function-name>" }.
 */
export function captureError(
  err: unknown,
  context: { function: string; [key: string]: unknown } = { function: "unknown" }
): void {
  // Always log locally regardless of whether Sentry is configured -- this
  // is what shows up in `supabase functions logs` either way.
  console.error(`[${context.function}]`, err);

  if (!parsed) {
    return; // SENTRY_DSN not set -- no-op beyond the console.error above.
  }

  const error = err instanceof Error ? err : new Error(typeof err === "string" ? err : JSON.stringify(err));
  const { function: fnName, ...extra } = context;

  const event = {
    event_id: eventId(),
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

  const endpoint = `https://${parsed.host}/api/${parsed.projectId}/store/`;

  // Deliberately not awaited by callers -- but we do fire the request here
  // rather than using a bare `fetch(...)` with no error handling, so a
  // network failure reporting to Sentry doesn't produce an unhandled
  // rejection in the Deno runtime.
  fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Sentry-Auth": `Sentry sentry_version=7, sentry_key=${parsed.publicKey}, sentry_client=returnkits-edge/1.0`,
    },
    body: JSON.stringify(event),
  }).catch((sentryErr) => {
    console.error(`[${fnName}] failed to report to Sentry:`, sentryErr);
  });
}
