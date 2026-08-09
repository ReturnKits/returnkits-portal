// supabase/functions/send-checkin-notifications/index.ts
//
// Hand-written. Runs on a pg_cron schedule (see the trigger_checkin_cron
// migration) and fires "have you sent it back?" / "has it arrived?" nudges
// for orders that qualify per orders_needing_checkin() (5 working days
// since dispatch, not yet confirmed, not nudged in the last 3 days).
//
// Deliberately thin: all eligibility logic lives in SQL
// (orders_needing_checkin(), architecture-testable via the RLS/behaviour
// suite without needing to fake cron time), and all rendering/sending
// logic is send-order-email's -- this function just connects the two, so
// there is exactly one place that builds a checkin_sent/checkin_received
// email regardless of whether it was triggered by a real order lifecycle
// event or by cron.
//
// Sending-hours gate (architecture §21): checked here via
// within_sending_hours(now()), NOT by constraining the pg_cron schedule to
// a UTC window -- Europe/London shifts between GMT and BST across the
// year, so a UTC cron expression would silently fire an hour off for half
// of it. The cron schedule runs hourly, every day; this function decides
// whether that's actually an appropriate moment to send anything.
//
// Auth: same shared-service_role model as every other internal endpoint --
// requires `Authorization: Bearer <service_role key>`, called by pg_cron
// via net.http_post reading the key from Vault (see trigger_checkin_cron).

import { createClient } from "jsr:@supabase/supabase-js@2";
import { captureError } from "../_shared/sentry.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!supabaseUrl || !serviceRoleKey) {
  console.error("send-checkin-notifications: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
}

const supabase = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "send-checkin-notifications" });
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
  if (authHeader !== `Bearer ${serviceRoleKey}`) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  const { data: sendingHoursOk } = await supabase.rpc("within_sending_hours", { p_ts: new Date().toISOString() });
  if (!sendingHoursOk) {
    return new Response(JSON.stringify({ skipped: true, reason: "outside sending hours" }), { status: 200 });
  }

  const { data: candidates, error } = await supabase.rpc("orders_needing_checkin");
  if (error) {
    captureError(error, { function: "send-checkin-notifications", step: "orders_needing_checkin" });
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }

  const rows = (candidates ?? []) as { order_id: string; checkin_type: string }[];
  const results: { orderId: string; type: string; ok: boolean }[] = [];

  for (const row of rows) {
    try {
      const resp = await fetch(`${supabaseUrl}/functions/v1/send-order-email`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${serviceRoleKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ orderId: row.order_id, type: row.checkin_type }),
      });
      results.push({ orderId: row.order_id, type: row.checkin_type, ok: resp.ok });
      if (!resp.ok) {
        captureError(new Error(`send-order-email returned ${resp.status} for check-in`), {
          function: "send-checkin-notifications",
          orderId: row.order_id,
          type: row.checkin_type,
          status: resp.status,
        });
      }
    } catch (err) {
      captureError(err, {
        function: "send-checkin-notifications",
        orderId: row.order_id,
        type: row.checkin_type,
        step: "fetch send-order-email",
      });
      results.push({ orderId: row.order_id, type: row.checkin_type, ok: false });
    }
  }

  return new Response(JSON.stringify({ processed: results.length, results }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}
