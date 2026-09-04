// supabase/functions/send-order-email/index.ts
//
// Hand-written per CLAUDE.md. Renders one of the transactional emails
// (architecture §21) and sends it via Resend. Called two ways:
//   1. From Postgres triggers on `orders` (payment_status -> paid,
//      fulfilment_status -> dispatched), via pg_net.http_post -- see the
//      Phase 5 trigger migration.
//   2. From the pg_cron check-in job (checkin_sent).
//
// checkin_received ("has your kit arrived?", ship_to_new_employee orders)
// was removed 20260827: Sendcloud's "delivered" auto-complete (webhook +
// hourly scheduled poll fallback) already closes these orders out
// automatically off the outbound leg's tracking, making the manual
// "please confirm in your portal" ask redundant with a working automated
// signal rather than a needed safety net. See CLAUDE.md's "check-in
// reminders routed to the employee first" entry for the full reasoning.
//
// return_confirmed (added, then removed same week) briefly closed the loop
// for return orders once a customer self-reported posting the device back.
// Retired in 20260811090000_remove_confirm_sent.sql: a customer's own
// say-so isn't a reliable signal, and it silently exempted the order from
// the check-in nudge. Return orders now just stay 'dispatched' until either
// staff record physical receipt or (later, deferred) Sendcloud tracking
// confirms it -- checkin_sent keeps nudging every few days in the meantime,
// which is the intended behaviour now, not a gap.
//
// Templates: plain typed TypeScript functions building HTML strings, NOT
// @react-email/components + @react-email/render as architecture §21
// originally specified. Deliberate substitution, same category as pdf-lib
// over React-PDF elsewhere in this codebase: a live test (Phase 5) showed
// React's server-render path crashing at boot in this project's Deno edge
// runtime (500, no captured log line -- consistent with an npm import
// failure during module init, before any request-level code runs). The
// architectural INTENT survives -- typed functions taking typed props, one
// place per template, no copy-pasted markup -- only the specific rendering
// mechanism changes.
//
// Visual style matched against the Base44 prototype's confirmation email
// (user-supplied reference screenshot) rather than invented from scratch:
// wordmark header, order meta line, itemised pricing, a destination block
// (return address, or the new starter's shipping address), numbered
// "what happens next" steps.
//
// Auth: same shared-service_role model as the rest of this project's
// internal write API (mark_order_dispatched, generate-print-pack) --
// Authorization header must equal `Bearer <service_role key>` exactly.
// pg_net calls carry this because the trigger reads it from Vault, never
// hardcoded in SQL.
//
// Bundle-aware (architecture §21: "one email per bundle"): order_confirmation
// looks up the order's bundle_id and, if present, includes every sibling
// order in that bundle as line items in a single email, and dedupes against
// ANY of those sibling order_ids already having a sent confirmation --
// whichever order in the bundle triggers first wins, the rest are no-ops.
//
// Idempotency: checked at the application level (query communication_log
// before sending) rather than a DB unique constraint, because the shape of
// "duplicate" differs by type -- one-shot for order_confirmation/dispatched,
// but checkin_sent is expected to legitimately repeat over an order's life
// (a fresh nudge every few working days) and get their own dedupe scheme
// (the 3-day cooldown in orders_needing_checkin()).

import { createClient } from "jsr:@supabase/supabase-js@2";

// Inlined from ../_shared/sentry.ts (20260813): the deploy_edge_function
// MCP tool wasn't reliably bundling the cross-function shared import --
// repeated deploys errored "Module not found ... _shared/sentry.ts" even
// with the file included in the payload, despite the exact same shared-file
// pattern working for this function's earlier versions (presumably deployed
// via the Supabase CLI directly, which handles the real functions/
// directory structure differently than this MCP tool's bundler does).
// Inlining is the pragmatic fix rather than continuing to guess at the
// tool's path semantics -- content is otherwise identical to
// supabase/functions/_shared/sentry.ts. If other functions hit the same
// bundling issue, worth revisiting whether the shared-module pattern is
// still viable for MCP-based deploys, or whether it needs the CLI.
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

// Portal's own custom domain (added for the check-in reminder restructure
// below). No request "origin" header is available in this context --
// send-checkin-notifications is cron-triggered, not a browser call -- so
// this is a plain hardcoded constant, same category as FROM_ADDRESS above.
// Used only to link the orderer straight to the employee directory from
// the no_email reminder branch, so the gap is one click to fix instead of
// a message that just repeats every few days.
const PORTAL_URL = "https://portal.returnkits.com";

if (!supabaseUrl || !serviceRoleKey || !resendApiKey) {
  console.error("send-order-email: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / RESEND_API_KEY");
}

const supabase = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");

type EmailType = "order_confirmation" | "dispatched" | "checkin_sent" | "return_in_transit";

const VALID_TYPES: EmailType[] = ["order_confirmation", "dispatched", "checkin_sent", "return_in_transit"];

// Fallback estimate when Sendcloud's tracking payload doesn't carry an
// expected_delivery_date (added 20260814 for return_in_transit -- see that
// section below). Judgment call, not derived from real delivery-time data;
// revisit if actual return-leg transit times suggest a different number.
const RETURN_IN_TRANSIT_FALLBACK_WORKING_DAYS = 2;

// Estimated delivery shown on the DISPATCHED email (added 20260820,
// replacing the courier name / tracking number / track button that used to
// be shown there -- see CLAUDE.md's "Dispatched email simplified" entry).
// Same reasoning as RETURN_IN_TRANSIT_FALLBACK_WORKING_DAYS above: no live
// carrier ETA is available at the moment this fires (labels are bought
// manually in Sendcloud's dashboard -- see CLAUDE.md's "Phase 6 is
// tracking-only" note -- so there's no synchronous rate/ETA call in this
// flow), so this is a plain working-day estimate off today's date via the
// same add_working_days() SQL helper. Judgment call, not derived from real
// delivery-time data; revisit if actual outbound transit times suggest a
// different number.
const DISPATCHED_ESTIMATED_DELIVERY_WORKING_DAYS = 2;

// ---- Check-in escalation tier (added 2026-08-26) -------------------------
//
// Third "final notice" stage on top of the existing first-send / follow-up
// pair for the return-order check-in reminder (checkin_sent). Counts how
// many times this exact type+audience+order combination has already been
// sent successfully (sent/delivered in communication_log) and adds one --
// 1 = first send, 2 = the pre-existing escalated follow-up, 3 = final
// notice, capped at 3 so a 4th, 5th, ... send all stay at tier 3 rather than
// climbing an unbounded ladder (direct requirement: repeats at the same
// cadence after the first tier-3 send, never becomes a new indefinite
// tier 4).
//
// Audience-agnostic since 20260827: originally computed separately per
// audience (customer vs employee), but the employee-first routing change
// that day made checkin_sent strictly either/or per order -- the employee
// gets it if eligible (notify_employee on + has an email), otherwise the
// customer gets it as a fallback, never both for the same send. With only
// one audience ever receiving a given order's checkin_sent, counting by
// audience and counting across the whole order converge to the same number
// in the overwhelming majority of cases, and simplifying to one counter
// avoids a subtle edge case: if eligibility flips mid-sequence (e.g. staff
// add a missing employee email between sends), a per-audience counter would
// have reset the newly-eligible side back to tier 1, silently re-starting
// the escalation the recipient (whichever one it now is) has actually
// already been through once.
type CheckinTier = 1 | 2 | 3;

async function computeCheckinTier(orderId: string): Promise<CheckinTier> {
  const { data: priorSends } = await supabase
    .from("communication_log")
    .select("id")
    .eq("type", "checkin_sent")
    .eq("order_id", orderId)
    .in("status", ["sent", "delivered"]);
  const priorCount = priorSends?.length ?? 0;
  return Math.min(priorCount + 1, 3) as CheckinTier;
}

// Deadline shown in the Tier 3 ("final notice") employee check-in email.
// Direct requirement: 5 working days from the send date, recomputed fresh on
// every tier-3 send (same "estimate computed fresh each time" pattern as
// DISPATCHED_ESTIMATED_DELIVERY_WORKING_DAYS / RETURN_IN_TRANSIT_FALLBACK_WORKING_DAYS
// above) via the same add_working_days() SQL helper. addWorkingDaysFallback()
// below is a deliberately approximate (no UK bank-holiday awareness)
// client-side fallback for the rare case that RPC call itself fails -- the
// alternative would be sending a final-notice email with no deadline at
// all, which defeats the point of it.
const CHECKIN_TIER3_DEADLINE_WORKING_DAYS = 5;

function addWorkingDaysFallback(start: Date, n: number): Date {
  const d = new Date(start);
  let added = 0;
  while (added < n) {
    d.setDate(d.getDate() + 1);
    const day = d.getDay();
    if (day !== 0 && day !== 6) added++;
  }
  return d;
}

// Simple substring match on the free-text courier field -- outbound_courier
// isn't an enum (Sendcloud/Retool can type anything in), so this is a best
// -effort hint for which carrier-specific guidance link to show, not a
// source of truth. Unrecognised couriers just get no link, never a wrong one.
function courierGuidanceUrl(courier: string | null): string | null {
  const c = (courier ?? "").toLowerCase();
  if (c.includes("royal mail")) return "https://www.postoffice.co.uk/branch-finder";
  if (c.includes("dpd")) return "https://www.dpd.co.uk/service/pickup";
  return null;
}

function pence(n: number): string {
  return `£${(n / 100).toFixed(2)}`;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });
}

// Single flowing line ("66 Sandhill Oval, Leeds, LS17 8EE") -- used for both
// return addresses and a new starter's shipping address, so the two
// "destination" blocks in the templates below render identically.
function formatAddressLine(line1: string | null, line2: string | null, city: string | null, postcode: string | null): string {
  return [line1, line2, city && postcode ? `${city}, ${postcode}` : city || postcode]
    .filter(Boolean)
    .map((part) => escapeHtml(part as string))
    .join(", ");
}

// Resolves employee name/email/address from EITHER a joined employees row
// OR the order-level manual-entry snapshot columns (20260813:
// orders.employee_name etc., used when the orderer typed a one-off
// recipient instead of picking from the directory -- orders_employee_source_check
// guarantees exactly one of the two is populated, never both, never
// neither). Every call site that used to read o.employees.* directly now
// goes through this so the manual path and the directory path render
// identically.
type EmployeeSource = {
  employees: { full_name: string; email: string | null; address_line1: string | null; address_line2: string | null; city: string | null; postcode: string | null; country: string | null } | null;
  employee_name: string | null;
  employee_email: string | null;
  employee_address_line1: string | null;
  employee_address_line2: string | null;
  employee_city: string | null;
  employee_postcode: string | null;
  employee_country: string | null;
};

function resolveEmployee(o: EmployeeSource): { name: string | null; email: string | null; addressLine: string } {
  if (o.employees) {
    return {
      name: o.employees.full_name,
      email: o.employees.email,
      addressLine: formatAddressLine(o.employees.address_line1, o.employees.address_line2, o.employees.city, o.employees.postcode),
    };
  }
  if (o.employee_name) {
    return {
      name: o.employee_name,
      email: o.employee_email,
      addressLine: formatAddressLine(o.employee_address_line1, o.employee_address_line2, o.employee_city, o.employee_postcode),
    };
  }
  return { name: null, email: null, addressLine: "" };
}

// ---- Shared layout ----------------------------------------------------

// Hosted in the public brand-assets Storage bucket (uploaded once via the
// one-off seed-brand-logo function) rather than the text wordmark this
// replaced -- the user supplied the actual logo file to match.
const LOGO_URL = "https://pzewknoohcqdqrrhwqrs.supabase.co/storage/v1/object/public/brand-assets/returnkits-wordmark.png";
const LOGO_IMG = `<img src="${LOGO_URL}" width="180" height="37" alt="ReturnKits" style="display:block;border:0;outline:none;text-decoration:none;height:37px;width:180px;" />`;

// Table-based, not div-based -- Outlook desktop/OWA render HTML email with
// Microsoft Word's engine, not a browser: it ignores max-width, border-radius,
// and CSS background on <a>, and margin:0 auto centering doesn't reliably
// work on <div>. A live Outlook screenshot (user-reported) showed the card
// rendering full-bleed instead of a centered 520px box, and the tracking
// button as a plain highlighted link instead of a button -- both are exactly
// the symptoms of Word-engine div/CSS limitations, not a bug in the content.
// Fix: explicit width="520" HTML attribute (not just CSS) on a real <table>,
// which Word's engine does honour, and MSO conditional comments to pin the
// width even more precisely in Outlook specifically. border-radius on the
// button still won't render in Outlook (square corners there) -- acceptable
// graceful degradation, not worth a VML round-corner hack for this size app.
//
// Second Outlook pass: the first fix pinned the width but the card still
// rendered edge-to-edge with no visible boundary in a live screenshot. Root
// cause -- background-color set only via CSS `style` on <body> and the
// outer 100%-wide table, no `bgcolor` attribute. Word ignores CSS
// background-color on table/body, so the grey page background never
// painted and the white card had nothing to contrast against. Same class of
// bug as the button fix: attribute, not just CSS. Also switched the card's
// border from shorthand (`border: 1px solid ...`) to the same three-property
// longhand already proven to work on the <hr> below -- Word's CSS parser
// drops shorthand border on tables even when it paints bgcolor correctly.
function layout(previewText: string, bodyHtml: string): string {
  return `<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<!--[if mso]>
<noscript>
<xml>
<o:OfficeDocumentSettings>
<o:PixelsPerInch>96</o:PixelsPerInch>
<o:AllowPNG/>
</o:OfficeDocumentSettings>
</xml>
</noscript>
<![endif]-->
<title>${escapeHtml(previewText)}</title>
</head>
<body bgcolor="#f4f4f5" style="background-color:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;margin:0;padding:0;">
  <div style="display:none;max-height:0;overflow:hidden;">${escapeHtml(previewText)}</div>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#f4f4f5" style="background-color:#f4f4f5;">
    <tr>
      <td align="center" bgcolor="#f4f4f5" style="background-color:#f4f4f5;padding:24px 16px;">
        <!--[if mso]>
        <table role="presentation" width="520" cellpadding="0" cellspacing="0" border="0"><tr><td>
        <![endif]-->
        <table role="presentation" width="520" cellpadding="0" cellspacing="0" border="0" bgcolor="#ffffff" style="background-color:#ffffff;max-width:520px;width:100%;border-color:#e5e7eb;border-style:solid;border-width:1px;">
          <tr>
            <td style="padding:32px;">
              <div style="margin:0 0 28px;">${LOGO_IMG}</div>
              ${bodyHtml}
              <hr style="border-color:#e5e7eb;border-style:solid;border-width:1px 0 0;margin:28px 0 16px;" />
              <p style="font-size:12px;color:#9ca3af;margin:0 0 8px;">
                <a href="https://returnkits.com" style="color:#9ca3af;text-decoration:none;">returnkits.com</a>
                &nbsp;·&nbsp;
                <a href="mailto:support@returnkits.com" style="color:#9ca3af;text-decoration:none;">support@returnkits.com</a>
              </p>
              <p style="font-size:11px;color:#c4c8ce;margin:0;">UK Nationwide IT Asset Recovery. You're receiving this because you placed an order with ReturnKits.</p>
            </td>
          </tr>
        </table>
        <!--[if mso]>
        </td></tr></table>
        <![endif]-->
      </td>
    </tr>
  </table>
</body>
</html>`;
}

function metaRow(label: string, value: string): string {
  return `<tr>
    <td style="padding:6px 0;font-size:13px;color:#6b7280;">${escapeHtml(label)}</td>
    <td style="padding:6px 0;font-size:13px;color:#111827;font-weight:600;text-align:right;">${value}</td>
  </tr>`;
}

function field(label: string, value: string): string {
  return `<div style="margin:0 0 12px;">
    <p style="font-size:12px;color:#6b7280;margin:0;">${escapeHtml(label)}</p>
    <p style="font-size:14px;color:#111827;font-weight:600;margin:0;">${escapeHtml(value)}</p>
  </div>`;
}

// A single "who/where this is going" block -- shared markup for a return
// order's return address and a ship-to-new-employee order's recipient, so
// both templates present destination info identically.
function destinationBlock(heading: string, name: string, addressLine: string): string {
  return `<h2 style="font-size:14px;font-weight:700;color:#111827;margin:24px 0 8px;">${escapeHtml(heading)}</h2>
    <p style="font-size:14px;color:#111827;margin:0 0 2px;font-weight:600;">${escapeHtml(name)}</p>
    <p style="font-size:14px;color:#374151;margin:0;line-height:20px;">${addressLine}</p>`;
}

// Plain bold number instead of a circular badge -- border-radius doesn't
// render in Outlook's Word engine (see layout()'s comment), so the earlier
// version showed as a small blue square rather than a circle. Rather than
// fight it with a VML circle for three list items, drop the shape and keep
// just the bold coloured numeral -- reads cleanly in every client.
function numberedSteps(steps: string[]): string {
  const rows = steps
    .map(
      (step, i) => `<tr>
        <td style="width:20px;vertical-align:top;padding:6px 8px 6px 0;font-size:13px;font-weight:700;color:#2563eb;">${i + 1}.</td>
        <td style="padding:6px 0;font-size:14px;color:#374151;">${escapeHtml(step)}</td>
      </tr>`,
    )
    .join("");
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="width:100%;margin:0 0 20px;">${rows}</table>`;
}

// ---- Order confirmation (bundle-aware) --------------------------------

type ConfirmationLine = {
  reference: string;
  kitLabel: string;
  serviceType: string;
  priceExVatPence: number;
  employeeName: string | null;
  employeeAddress: string | null;
};
type ReturnAddress = { label: string | null; address_line1: string; address_line2: string | null; city: string; postcode: string; country: string };

function buildOrderConfirmationEmail(props: {
  companyName: string;
  createdAt: string;
  lines: ConfirmationLine[];
  bundleReference: string | null;
  returnAddress: ReturnAddress | null;
}): string {
  const totalExVat = props.lines.reduce((sum, l) => sum + l.priceExVatPence, 0);
  // VAT line removed 2026-08-26: ReturnKits' actual VAT rate was set to 0%
  // in the database on 2026-08-18 (not VAT-registered), and VAT display
  // language was stripped from the portal and invoice PDF the next day --
  // this template was missed in that pass and was still hardcoding a local
  // 20% calculation, showing a live "VAT (20%)" line and a 20%-inflated
  // total that didn't match what the customer was actually charged. Fixed
  // the same way the portal/invoice pages were: collapse to a single Total
  // row rather than computing a rate this template has no real per-line
  // access to anyway (it isn't sent kit_types.vat_rate/cover_tiers.vat_rate
  // per line -- and every rate in the DB is 0% regardless).
  const totalIncVat = totalExVat;

  const refs = props.lines.map((l) => l.reference);
  const primaryRef = refs[0] ?? "";
  const moreCount = refs.length - 1;
  // Not deduped -- matches the reference design, which lists one kit label
  // per line item ("Laptop Kit, Laptop Kit, Laptop Kit") rather than a
  // unique set. Order confirmations are short-lived reads; repetition here
  // mirrors the line items below it rather than compressing them away.
  const kitLabelsJoined = props.lines.map((l) => l.kitLabel).join(", ");
  const uniqueKitLabels = [...new Set(props.lines.map((l) => l.kitLabel))].join(", ");

  const lineItems = props.lines
    .map(
      (line) => `<tr>
        <td style="padding:8px 0;font-size:14px;color:#111827;border-bottom:1px solid #f3f4f6;">${escapeHtml(line.kitLabel)}</td>
        <td style="padding:8px 0;font-size:14px;color:#111827;text-align:right;vertical-align:top;border-bottom:1px solid #f3f4f6;">${pence(line.priceExVatPence)}</td>
      </tr>`,
    )
    .join("");

  const hasReturn = props.lines.some((l) => l.serviceType === "return");
  const hasShipToEmployee = props.lines.some((l) => l.serviceType !== "return");
  const steps: string[] = ["We dispatch within 1 working day"];
  if (hasReturn) steps.push("Recipient packs the device securely", "Device returned via prepaid tracked label");
  if (hasShipToEmployee) steps.push("New starter receives and sets up their kit");

  const returnAddressLine = props.returnAddress
    ? formatAddressLine(props.returnAddress.address_line1, props.returnAddress.address_line2, props.returnAddress.city, props.returnAddress.postcode)
    : "";
  const returnBlock = props.returnAddress
    ? destinationBlock("Return destination", props.returnAddress.label ?? props.companyName, returnAddressLine)
    : "";

  // One block per distinct new-starter recipient -- lets whoever placed the
  // order double-check the name/address before it ships, since the employee
  // themself never sees this email (CLAUDE.md: employees never log in, and
  // only orders.created_by is ever emailed).
  const seenEmployees = new Set<string>();
  const shippingBlocks = props.lines
    .filter((l) => l.serviceType !== "return" && l.employeeName)
    .filter((l) => {
      const key = `${l.employeeName}|${l.employeeAddress}`;
      if (seenEmployees.has(key)) return false;
      seenEmployees.add(key);
      return true;
    })
    .map((l) => destinationBlock("Shipping to", l.employeeName as string, l.employeeAddress ?? ""))
    .join("");

  const body = `
    <p style="font-size:12px;color:#9ca3af;margin:0 0 4px;">Order ${escapeHtml(primaryRef)}${moreCount > 0 ? ` (+${moreCount} more)` : ""} · ${formatDate(props.createdAt)}</p>
    <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">Your order is confirmed</h1>
    <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 20px;">Hi ${escapeHtml(props.companyName)}, thank you for your order. We've received payment and your ${escapeHtml(kitLabelsJoined)} is now being prepared for dispatch — you'll get another email with tracking details as soon as it's on its way.</p>
    <table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;margin:0 0 20px;">
      ${metaRow("Order ID", refs.join(", "))}
      ${metaRow("Order date", formatDate(props.createdAt))}
      ${metaRow("Kit types", uniqueKitLabels)}
    </table>
    <table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;">
      ${lineItems}
      <tr><td style="padding:10px 0 0;font-size:15px;color:#111827;font-weight:700;">Total paid</td><td style="padding:10px 0 0;font-size:15px;color:#111827;font-weight:700;text-align:right;">${pence(totalIncVat)}</td></tr>
    </table>
    ${returnBlock}
    ${shippingBlocks}
    <h2 style="font-size:14px;font-weight:700;color:#111827;margin:24px 0 12px;">What happens next</h2>
    ${numberedSteps(steps)}
    <p style="font-size:13px;line-height:20px;color:#6b7280;margin:20px 0 0;">Questions about your order? Just reply to this email, or reach us at <a href="mailto:support@returnkits.com" style="color:#2563eb;text-decoration:none;">support@returnkits.com</a>.</p>
  `;

  return layout(`Order confirmed — ${primaryRef}${moreCount > 0 ? ` (+${moreCount} more)` : ""}`, body);
}

// ---- Dispatched ---------------------------------------------------------

// Table-cell-with-bgcolor button, not a styled <a> -- Outlook's Word engine
// ignores CSS `background` on links entirely, which is what made this render
// as a plain highlighted link instead of a button (see layout()'s comment).
// bgcolor is an HTML attribute, not CSS, and Word honours it reliably.
function trackButton(url: string): string {
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:16px 0 4px;"><tr>
    <td bgcolor="#2563eb" style="background-color:#2563eb;border-radius:8px;">
      <a href="${escapeHtml(url)}" style="display:block;color:#ffffff;font-size:13px;font-weight:600;text-decoration:none;padding:10px 18px;">Track your delivery</a>
    </td>
  </tr></table>`;
}

// Shared drop-off numbered steps + courier guidance link -- used by
// buildEmployeeDispatchedEmail (the normal case: the employee is the one
// who actually packs and posts the device, so they get the real
// instructions) and, as a fallback, by buildDispatchedEmail's customer copy
// when notify_employee is off and there's no other channel to deliver
// these instructions through. Factored out 20260820 during the logic
// review below rather than duplicated across both templates.
//
// Home-collection line (added 20260821, same day as the wider Royal Mail
// return-model change): free drop-off is still the default numbered steps
// above, but the employee can instead scan the QR code already printed on
// the physical instruction card in the box to self-book a Royal Mail home
// collection for 30p (Royal Mail's real "Parcel Collect" service, booked
// at royalmail.com/collection -- confirmed via web search, and explicitly
// NOT the same product as Royal Mail's own "Labels to Go" QR code, which
// does label printing at a shop rather than booking a collection -- see
// the CLAUDE.md entry for this feature). No QR image is generated here --
// the card is already physically in the box, confirmed by the user -- this
// is purely a one-line pointer to it. ReturnKits has no visibility into
// whether this option gets used (no booking-time signal from Royal Mail),
// and the 30p is charged by Royal Mail directly to the employee -- zero
// financial involvement for ReturnKits either way, so nothing here needs
// to touch pricing/invoicing.
function dropOffSteps(courier: string): string {
  const guidanceUrl = courierGuidanceUrl(courier);
  const isDpd = courier.toLowerCase().includes("dpd");
  return `
    ${numberedSteps([
      "Pack the device securely using the materials enclosed in the kit",
      "Attach the prepaid return label that's already inside the box — no need to print anything",
      guidanceUrl
        ? `Drop it off with ${escapeHtml(courier)}${isDpd ? " (use the link below to arrange a collection)" : " (use the link below to find a drop-off point)"}`
        : `Drop it off with ${escapeHtml(courier)}`,
    ])}
    ${guidanceUrl ? `<p style="margin:0 0 20px;"><a href="${escapeHtml(guidanceUrl)}" style="color:#2563eb;font-size:13px;text-decoration:none;font-weight:600;">${isDpd ? "Arrange a DPD collection" : "Find a drop-off point"} →</a></p>` : ""}
    <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 20px;">
      Prefer someone to collect it instead? Scan the QR code on the instruction card inside the box to book a Royal Mail home collection for 30p — pick a day you know you'll be in.
    </p>
  `;
}

function buildDispatchedEmail(props: {
  companyName: string;
  reference: string;
  kitLabel: string;
  serviceType: string;
  courier: string;
  estimatedDeliveryDate: string | null;
  employeeName: string | null;
  employeeAddress: string | null;
  notifyEmployee: boolean;
  returnMethod: "drop_off" | "collection";
  collectionDate: string | null;
}): string {
  const isReturn = props.serviceType === "return";

  // Same reasoning as the confirmation email's shipping block -- the person
  // reading this isn't the recipient, so show them who/where it's going.
  const shippingBlock = !isReturn && props.employeeName ? destinationBlock("Shipping to", props.employeeName, props.employeeAddress ?? "") : "";

  // Courier name + tracking number + track button removed 20260820 (direct
  // user request) in favour of a plain estimated-delivery line -- see
  // DISPATCHED_ESTIMATED_DELIVERY_WORKING_DAYS above. Same "around ...
  // estimates can shift" caveat style as the return_in_transit email, for
  // the same reason: this is a working-day estimate, not a carrier-sourced
  // promise.
  const etaLine = props.estimatedDeliveryDate
    ? `<p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 20px;">Estimated delivery: around ${escapeHtml(formatDate(props.estimatedDeliveryDate))}. Courier estimates can shift by a day or so.</p>`
    : "";

  const employeeDisplay = escapeHtml(props.employeeName ?? "the recipient");

  // Reframed 20260820 -- a code review the user asked for flagged a real
  // logic bug here: this email goes to the ORDERER, not the person who
  // physically has the box. For a return order that's the employee, who
  // packs and hands over/posts the device -- the previous copy gave direct
  // second-person packing instructions ("Pack the device...", "Drop it
  // off...") to someone who usually can't act on them. Now this is purely
  // informational whenever the employee has their own copy to act on (see
  // buildEmployeeDispatchedEmail below, which now carries the real
  // step-by-step + courier link), and only falls back to full instructions
  // here when notify_employee is off -- since then this IS the only place
  // they exist at all, and the orderer needs to relay them manually.
  let nextStepsBlock: string;
  if (!isReturn) {
    nextStepsBlock = `<p style="font-size:13px;line-height:20px;color:#6b7280;margin:20px 0 0;">Nothing further to do on your end once it arrives with the new starter — we'll follow up to confirm.</p>`;
  } else {
    // Genericized 20260821 alongside the reminder copy -- "pack and post"
    // assumed drop-off specifically, which is no longer the only option
    // now that a QR code in the box lets the employee self-book a 30p
    // Royal Mail home collection instead. See dropOffSteps()'s own comment
    // for the full context.
    const methodLine =
      props.returnMethod === "collection" && props.collectionDate
        ? `A courier will collect the old device from ${employeeDisplay} around ${escapeHtml(formatDate(props.collectionDate))}. Courier estimates can shift by a day or so.`
        : `${employeeDisplay} has everything needed to send the device back, including a prepaid return label and a QR code to book a home collection instead, if that's easier.`;

    if (props.notifyEmployee) {
      nextStepsBlock = `
        <h2 style="font-size:14px;font-weight:700;color:#111827;margin:24px 0 12px;">What happens next</h2>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 4px;">${methodLine}</p>
        <p style="font-size:13px;line-height:20px;color:#6b7280;margin:12px 0 0;">We've sent ${employeeDisplay} the full instructions directly — nothing further needed from you. We'll let you know once it's back with us.</p>
      `;
    } else {
      nextStepsBlock = `
        <h2 style="font-size:14px;font-weight:700;color:#111827;margin:24px 0 12px;">What happens next</h2>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">${methodLine}</p>
        <p style="font-size:13px;line-height:20px;color:#6b7280;margin:0 0 12px;">Employee notifications aren't turned on for this order, so here's what to pass on to ${employeeDisplay}:</p>
        ${
          props.returnMethod === "collection"
            ? numberedSteps([
                "Pack the device securely using the materials enclosed in the kit",
                "Attach the prepaid return label that's already inside the box — no need to print anything",
                "Have it ready to hand to the courier on the collection date — no drop-off needed",
              ])
            : dropOffSteps(props.courier)
        }
      `;
    }
  }

  const body = `
    <p style="font-size:12px;color:#9ca3af;margin:0 0 4px;">Order ${escapeHtml(props.reference)}</p>
    <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">Your kit is on its way</h1>
    <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 20px;">${escapeHtml(props.kitLabel)} for ${escapeHtml(props.companyName)} has been dispatched.</p>
    ${shippingBlock}
    ${etaLine}
    ${nextStepsBlock}
  `;

  return layout(`On its way — ${props.reference}`, body);
}

// ---- Check-in: have you sent it back? (return orders) -------------------

// No longer asks the customer to confirm anything -- confirm_sent was
// removed (20260811090000_remove_confirm_sent.sql) because a self-reported
// "yes I sent it" isn't verifiable. This is now a plain reminder with no
// action to take beyond actually posting the device; orders_needing_checkin()
// keeps sending this every few days for as long as the order sits in
// 'dispatched', which is the point -- reminders continue until it's
// actually sent.
//
// The orderer isn't the one holding the device (the kit ships to the
// employee's address, not theirs), so a bare "please post it back"
// instruction doesn't fit them -- this is a visibility/escalation signal
// for whoever's managing the offboarding, not a direct action request.
// Added 20260816: the copy now tells the orderer whether the employee is
// also being nudged directly, and if not, *why* -- three distinct states,
// not one generic fallback, because the two "not notified" reasons are
// different in kind: notify_off is the orderer's own choice at order
// creation (nothing broken, they can act on it by following up
// themselves), whereas no_email is a real data gap they could go fix
// (add the employee's email to the directory) so notifications work
// correctly going forward. Collapsing those two into one message would
// have repeated the same inaccuracy problem the 'notified' claim itself
// would have had if shown unconditionally.
//
// Narrowed to two values 20260827: the employee-first routing change that
// day means the customer only ever receives checkin_sent when the employee
// ISN'T being notified directly (notify_employee off, or no email on file)
// -- when the employee IS eligible, they get it instead and the customer
// gets nothing for this event. "notified" is therefore no longer a state
// the customer-facing template can ever be asked to render; the branch was
// removed outright rather than left dead, matching this project's own
// practice elsewhere (see confirm_sent's full removal).
type CheckinSentEmployeeStatus = "notify_off" | "no_email";

// "Kit" on its own is ambiguous once a company has more than one return in
// flight -- device_reference (asset tag / serial, optional at order
// creation) disambiguates when it's present, without changing anything for
// the majority of orders that don't set it.
function deviceLabel(kitLabel: string, deviceReference: string | null): string {
  return deviceReference ? `${kitLabel} (${escapeHtml(deviceReference)})` : escapeHtml(kitLabel);
}

// Restructured 20260820 off a direct question from the user ("if you were
// to restructure the email reminders, how would you structure them?").
// Two real gaps in the previous single-shape reminder:
//
// 1. It used the same "please post it back" copy regardless of
//    return_method -- but a courier-collection order has nothing for
//    anyone to post; the eligibility gate below (orders_needing_checkin())
//    now only fires this for a collection order once its collection_date
//    has passed without the leg moving to in_transit/completed, so the
//    honest framing here is "this looks like a missed collection," not a
//    generic nag.
// 2. The no_email branch just repeated "we don't have an email on file"
//    forever with nothing actionable in the email itself. It now links
//    straight to the employee directory so the orderer can fix the actual
//    gap in one click, rather than being told about it on a loop.
function buildCheckinSentEmail(props: {
  companyName: string;
  reference: string;
  kitLabel: string;
  deviceReference: string | null;
  employeeName: string | null;
  employeeStatus: CheckinSentEmployeeStatus;
  returnMethod: "drop_off" | "collection";
  collectionDate: string | null;
  tier: CheckinTier;
}): string {
  const employeeDisplay = escapeHtml(props.employeeName ?? "the recipient");
  const itemLabel = deviceLabel(props.kitLabel, props.deviceReference);
  const employeeDirectoryLink = `<a href="${PORTAL_URL}/employees" style="color:#2563eb;text-decoration:none;">employee directory</a>`;
  const isCollectionOverdue = props.returnMethod === "collection";

  // Tier 3 ("final notice", added 2026-08-26): unified copy regardless of
  // return_method -- direct requirement ("both order types") -- unlike
  // tiers 1/2 below, which still branch on drop-off vs collection.
  // Employee-status-aware, same split used everywhere else in this file --
  // narrowed to two branches 20260827 (see CheckinSentEmployeeStatus's own
  // comment): the "notified" case can't occur here anymore, since a
  // notified employee is the one getting emailed directly now, not the
  // customer.
  if (props.tier === 3) {
    let bodyHtml: string;
    if (props.employeeStatus === "notify_off") {
      bodyHtml = `
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          ${escapeHtml(props.kitLabel)} still isn't back with us after several reminders on our end. We haven't been able to remind ${employeeDisplay} directly, since employee notifications weren't turned on for this order.
        </p>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0;">
          This is a final nudge before we flag it as outstanding — you may want to follow up with them directly.
        </p>
      `;
    } else {
      bodyHtml = `
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          ${escapeHtml(props.kitLabel)} still isn't back with us after several reminders on our end. We don't have an email on file for ${employeeDisplay}, so we haven't been able to remind them directly.
        </p>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0;">
          This is a final nudge before we flag it as outstanding — you may want to follow up with them directly, or add their email from the ${employeeDirectoryLink} so future reminders reach them.
        </p>
      `;
    }
    const tier3Body = `
      <p style="font-size:12px;color:#9ca3af;margin:0 0 4px;">Order ${escapeHtml(props.reference)}</p>
      <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">Still outstanding</h1>
      ${bodyHtml}
    `;
    return layout(`Still outstanding — ${props.reference}`, tier3Body);
  }

  let heading: string;
  let bodyHtml: string;

  if (isCollectionOverdue) {
    heading = "Collection may have been missed";
    const dateLine = props.collectionDate ? ` around ${escapeHtml(formatDate(props.collectionDate))}` : "";

    let followUp: string;
    if (props.employeeStatus === "notify_off") {
      followUp = `Employee notifications weren't turned on for this order, so ${employeeDisplay} hasn't heard from us about this — you may want to give them a heads-up.`;
    } else {
      followUp = `We don't have an email on file for ${employeeDisplay}, so they haven't heard from us about this — you may want to give them a heads-up. Add their email from the ${employeeDirectoryLink} and future updates will reach them directly.`;
    }

    bodyHtml = `
      <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
        ${itemLabel} for ${escapeHtml(props.companyName)} was due to be collected${dateLine}, but we haven't had it confirmed as picked up yet.
      </p>
      <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
        ${followUp}
      </p>
      <p style="font-size:13px;line-height:20px;color:#6b7280;margin:0;">We're following this up on our end — no action needed from you unless you'd like to check in yourself.</p>
    `;
  } else {
    heading = "Just a reminder";
    const baseLine = `We haven't seen ${itemLabel} for ${escapeHtml(props.companyName)} come back to us yet.`;

    let followUp: string;
    if (props.employeeStatus === "notify_off") {
      followUp = `You may want to follow up with ${employeeDisplay} directly — employee notifications weren't turned on for this order.`;
    } else {
      followUp = `You may want to follow up with ${employeeDisplay} directly — we don't have an email on file for them. Add one from the ${employeeDirectoryLink} and future reminders will reach them directly.`;
    }

    bodyHtml = `
      <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
        ${baseLine} ${followUp} We'll take it from there once it arrives — no need to let us know.
      </p>
    `;
  }

  const body = `
    <p style="font-size:12px;color:#9ca3af;margin:0 0 4px;">Order ${escapeHtml(props.reference)}</p>
    <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">${heading}</h1>
    ${bodyHtml}
  `;
  const previewText = isCollectionOverdue
    ? `Collection check — ${props.reference}`
    : `Reminder: please send your kit back — ${props.reference}`;
  return layout(previewText, body);
}

// ---- Return in transit (return orders, added 20260814) ------------------
//
// Fires once, when a return order's fulfilment_status moves
// dispatched -> in_transit off the return leg's tracking number (the
// courier's first scan after the leaver hands the box over) -- see
// apply_sendcloud_tracking_event()/apply_sendcloud_poll_result() and the
// two Edge Functions that call them. Deliberately customer-only, never an
// employee copy: the leaver has already done their part by the time this
// fires and has no portal access to check anything further, so there's
// nothing for them to act on -- see the design discussion in CLAUDE.md.
// estimatedArrivalDate is resolved by the caller (either Sendcloud's own
// expected_delivery_date from the tracking payload, confirmed present in a
// real response 20260814, or a working-day fallback) and passed straight
// through here rather than recomputed -- this function only renders it.
function buildReturnInTransitEmail(props: {
  companyName: string;
  reference: string;
  kitLabel: string;
  courier: string;
  trackingNumber: string;
  trackingUrl: string | null;
  estimatedArrivalDate: string | null;
}): string {
  const trackingBlock = `
    ${field("Courier", props.courier)}
    ${field("Tracking number", props.trackingNumber)}
    ${props.trackingUrl ? trackButton(props.trackingUrl) : ""}
  `;

  // "Around" + explicit caveat rather than a bare date -- a real Sendcloud
  // expected_delivery_date checked 20260814 was a day early against the
  // parcel's actual delivery, so this deliberately reads as an estimate,
  // never a promise.
  const etaLine = props.estimatedArrivalDate
    ? `<p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 20px;">Estimated arrival: around ${escapeHtml(formatDate(props.estimatedArrivalDate))}. Courier estimates can shift by a day or so.</p>`
    : "";

  const body = `
    <p style="font-size:12px;color:#9ca3af;margin:0 0 4px;">Order ${escapeHtml(props.reference)}</p>
    <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">Your return is on its way back</h1>
    <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">${escapeHtml(props.kitLabel)} for ${escapeHtml(props.companyName)} has been collected and is heading back to us.</p>
    ${etaLine}
    ${trackingBlock}
    <p style="font-size:13px;line-height:20px;color:#6b7280;margin:20px 0 0;">We'll let you know once it's arrived — nothing further to do on your end.</p>
  `;

  return layout(`Return in progress — ${props.reference}`, body);
}

// ---- Employee-facing copies (20260813, dispatched + checkin_sent only) --
//
// Passive notices to the employee named on the order (orders.employee_id ->
// employees.email) -- NOT the portal user who placed it. Deliberately
// minimal: no pricing, no reference number, no company billing detail, per
// the explicit "I don't want the employee to get order details" ask. Only
// built for 'dispatched' and 'checkin_sent' -- see the accompanying
// migration's comment for why those two specifically and not
// order_confirmation. (checkin_received no longer exists at all as of
// 20260827 -- see the top-of-file comment.)

function buildEmployeeDispatchedEmail(props: {
  employeeName: string;
  companyName: string;
  serviceType: string;
  courier: string;
  trackingUrl: string | null;
  returnMethod: "drop_off" | "collection";
  collectionDate: string | null;
}): string {
  const isReturn = props.serviceType === "return";

  // Rewritten 20260820 (same review as buildDispatchedEmail above): this is
  // the person who actually has the box, so this is where the real
  // step-by-step + courier-specific guidance link belongs -- it used to
  // only exist in the customer's copy, addressed to someone who couldn't
  // act on it. Also now branches on return_method: when a collection has
  // been arranged, there's nothing to drop off or look up, just a date to
  // expect the courier.
  let whatNext: string;
  if (!isReturn) {
    whatNext = `<p style="font-size:14px;line-height:22px;color:#374151;margin:16px 0 0;">
         Nothing else to do once it arrives — it's ready to use.
       </p>`;
  } else if (props.returnMethod === "collection" && props.collectionDate) {
    whatNext = `
      <h2 style="font-size:14px;font-weight:700;color:#111827;margin:24px 0 12px;">Sending it back</h2>
      <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
        A courier (${escapeHtml(props.courier)}) will collect it from you around ${escapeHtml(formatDate(props.collectionDate))}. Courier estimates can shift by a day or so.
      </p>
      <p style="font-size:14px;line-height:22px;color:#374151;margin:0;">
        Just have the device packed with the prepaid return label attached — both already inside the box — and ready to hand over. No need to arrange anything yourself.
      </p>
    `;
  } else {
    whatNext = `
      <h2 style="font-size:14px;font-weight:700;color:#111827;margin:24px 0 12px;">Sending it back</h2>
      ${dropOffSteps(props.courier)}
    `;
  }

  const body = `
    <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">A ReturnKits box is on its way to you</h1>
    <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 4px;">Hi ${escapeHtml(props.employeeName)},</p>
    <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 16px;">
      ${escapeHtml(props.companyName)} has arranged a ReturnKits delivery for you, sent via ${escapeHtml(props.courier)}.
    </p>
    ${props.trackingUrl ? trackButton(props.trackingUrl) : ""}
    ${whatNext}
  `;
  return layout("A ReturnKits box is on its way to you", body);
}

// Branches on return_method (added 20260820, same restructure as the
// customer copy above): a "please post it back" instruction is simply
// wrong for a collection order -- the employee didn't post anything and
// isn't the one who can rebook a missed courier, so the collection variant
// is deliberately reassuring rather than instructional. No device_reference
// here, unlike the customer copy -- an employee only ever has one open
// return of their own, so there's nothing to disambiguate.
//
// isFollowUp (added 20260820, same day): the first nudge and every nudge
// after it used to be byte-for-byte identical -- orders_needing_checkin()
// just re-fires the same email every 3 days for as long as the order sits
// in 'dispatched'/hasn't been collected, with no sense of "we've already
// asked." Direct user request: escalate tone on the repeat sends so the
// employee actually notices it's still open, without turning the first,
// perfectly reasonable reminder into something naggy. Deliberately a single
// escalated tier (not first/second/third/... each firmer) -- this project's
// own established discipline is to accept the smallest defensible v1 rather
// than build an unbounded tone ladder nobody asked for; every send from the
// second onward reuses the same escalated copy.
//
// The two branches escalate differently on purpose, not symmetrically: for
// drop-off, whether it goes back is genuinely the employee's own action, so
// the escalated copy can reasonably ask them to act and explain why it
// matters (security, accountability for company hardware). For collection,
// the employee has nothing left to do -- a missed pickup is a courier/ops
// problem -- so escalating by pressuring them would be both unfair and
// inaccurate; instead it just makes clear the issue is still open and asks
// for one small assist (make sure it's somewhere obviously collectable)
// rather than implying they're at fault.
function buildEmployeeCheckinSentEmail(props: {
  employeeName: string;
  companyName: string | null;
  returnMethod: "drop_off" | "collection";
  collectionDate: string | null;
  tier: CheckinTier;
  deadlineDate: string | null;
}): string {
  const isCollectionOverdue = props.returnMethod === "collection";
  const companyDisplay = props.companyName ? escapeHtml(props.companyName) : "your old employer";
  const deadlineDisplay = props.deadlineDate ? escapeHtml(formatDate(props.deadlineDate)) : "the date below";

  let previewText: string;
  let body: string;

  // Tier 3 ("final notice", added 2026-08-26): fires on the 3rd send onward
  // for this order+audience and repeats at the same cadence after that (see
  // computeCheckinTier()'s capping comment) -- this is the escalation
  // ceiling, not a new indefinite tier 4. Adds three things tier 1/2 never
  // had: a real deadline date, an explicit invitation to reply if something's
  // actually wrong (lost/damaged/etc -- the sequence had no way for the
  // employee to signal that before), and a plain statement that the company
  // will be told if it's still outstanding past the deadline. The collection
  // variant deliberately keeps tier 2's "not your fault" framing rather than
  // switching to pressure -- a missed pickup is still a courier/ops problem,
  // not something to blame the employee for, even at the final stage.
  if (props.tier === 3) {
    if (isCollectionOverdue) {
      previewText = "One last follow-up on your collection";
      body = `
        <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">One last follow-up</h1>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          Hi ${escapeHtml(props.employeeName)}, we've followed up about this twice now, and the courier still hasn't collected your old device from you. This isn't something you've done wrong — could you make sure it's ready and waiting by ${deadlineDisplay}?
        </p>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          If it's easier, you can also rebook the collection yourself using the QR code on the instruction card inside the box.
        </p>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          If there's a reason this hasn't happened yet — device is lost, damaged, or something else — just reply and let us know, we'll sort it from there.
        </p>
        <p style="font-size:13px;line-height:20px;color:#6b7280;margin:0;">
          After ${deadlineDisplay}, we'll need to let ${companyDisplay} know this is still outstanding.
        </p>
      `;
    } else {
      previewText = "One last reminder — please send your old device back";
      body = `
        <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">One last reminder</h1>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          Hi ${escapeHtml(props.employeeName)}, we've reached out about this twice now and still haven't had your old device back from ${companyDisplay}. Could you get it sent by ${deadlineDisplay}?
        </p>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          Everything you need is already in the box — pack it, attach the label, and either drop it off or scan the QR code for a home collection.
        </p>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          If there's a reason this hasn't happened yet — device is lost, damaged, or something else — just reply and let us know, we'll sort it from there.
        </p>
        <p style="font-size:13px;line-height:20px;color:#6b7280;margin:0;">
          After ${deadlineDisplay}, we'll need to let ${companyDisplay} know this is still outstanding.
        </p>
      `;
    }
    return layout(previewText, body);
  }

  const isFollowUp = props.tier === 2;

  if (isCollectionOverdue) {
    const dateLine = props.collectionDate ? ` around ${escapeHtml(formatDate(props.collectionDate))}` : "";
    if (isFollowUp) {
      previewText = "Still following up on your collection";
      body = `
        <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">Still following up on your collection</h1>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          Hi ${escapeHtml(props.employeeName)}, we flagged this before — the courier still hasn't collected your old device${dateLine}.
        </p>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          Nothing different needed from you — just keep it packed and ready to hand over. We're continuing to chase this directly with the courier.
        </p>
        <p style="font-size:13px;line-height:20px;color:#6b7280;margin:0;">
          One thing that can help: if it's somewhere obviously collectable (not tucked away), that makes a rescheduled pickup more likely to succeed first time.
        </p>
      `;
    } else {
      previewText = "We're following up on your collection";
      body = `
        <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">We're following up on your collection</h1>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          Hi ${escapeHtml(props.employeeName)}, a courier was due to collect your old device${dateLine}, but it doesn't look like that's happened yet.
        </p>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0;">
          Nothing for you to do differently — just keep it packed and ready to hand over. We're chasing this up and will let you know if anything changes.
        </p>
      `;
    }
  } else {
    if (isFollowUp) {
      // Same genericization as the first-send branch below -- "posting"
      // assumed drop-off, which is no longer the only option.
      previewText = "Still outstanding — please send your device back";
      body = `
        <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">Still waiting on this one</h1>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          Hi ${escapeHtml(props.employeeName)}, we sent a reminder about this already, but we still haven't had your old device back from ${companyDisplay}.
        </p>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          Everything you need to get it back to us is already in the box — no need to let us know once it's done.
        </p>
        <p style="font-size:13px;line-height:20px;color:#6b7280;margin:0;">
          Getting old company devices back promptly matters — it keeps them secure and properly accounted for, and closes this out for you.
        </p>
      `;
    } else {
      // Genericized 20260821, direct follow-up from the same conversation
      // as the Royal Mail return-model change: this used to say "please pop
      // it in the post," which assumed drop-off specifically. Since the
      // employee may instead have scanned the QR code in the box to book a
      // 30p Royal Mail home collection -- and we have no visibility into
      // which they picked (see the QR/return-model CLAUDE.md entry) -- the
      // reminder can no longer assume either. "Everything you need is
      // already in the box" covers both the prepaid label (drop-off) and
      // the QR code (home collection) without committing to one.
      previewText = "Just a reminder — please send your device back";
      body = `
        <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">Just a reminder</h1>
        <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
          Hi ${escapeHtml(props.employeeName)}, when you get a chance, please get your old device back to us —
          everything you need is already in the box, whichever option's easiest for you. No need to let anyone know once it's done.
        </p>
      `;
    }
  }
  return layout(previewText, body);
}

// Fires alongside the customer-facing send for 'dispatched'/'checkin_sent'
// only, independent of whether the customer send above succeeded -- these
// are two separate recipients and one failing shouldn't block the other.
// Silently no-ops if the order's employee has no email on file (an optional
// field) or if the event type isn't one of the two this applies to.
// Inherits the caller's notification_preferences gate for free -- this is
// only ever invoked after that check has already passed.
async function sendEmployeeCopy(props: {
  type: EmailType;
  order: { id: string; service_type: string; company: { id: string; name: string } };
  employeeEmail: string | null;
  employeeName: string | null;
  courier: string | null;
  trackingUrl: string | null;
  notifyEmployee: boolean;
  returnMethod: "drop_off" | "collection";
  collectionDate: string | null;
}): Promise<void> {
  if (props.type !== "dispatched" && props.type !== "checkin_sent") return;
  // Per-order opt-in (20260813, orders.notify_employee -- off by default).
  // The person placing the order decides, order by order, whether the
  // named employee gets these nudges at all. This sits ON TOP OF the
  // employee-has-no-email check below and the caller's own
  // notification_preferences gate -- all three must clear for a send.
  if (!props.notifyEmployee) return;
  if (!props.employeeEmail || !props.employeeName) return;

  const recipient = props.employeeEmail;

  // tier (added 20260820, extended to a 3rd stage 20260826, made
  // audience-agnostic 20260827): how many prior sent/delivered checkin_sent
  // nudges does this order already have, across whichever audience actually
  // received them? See computeCheckinTier()'s own comment for why it counts
  // rather than just checking existence, why it caps at 3, and why it
  // stopped filtering by audience -- see buildEmployeeCheckinSentEmail's own
  // comment for why tier 3 is one escalated ceiling, not an increasing
  // ladder, and why the two return_method branches escalate differently.
  // Doesn't apply to 'dispatched' -- that's a one-shot send, there's no
  // "follow-up" case for it.
  let tier: CheckinTier = 1;
  let deadlineDate: string | null = null;
  if (props.type === "checkin_sent") {
    tier = await computeCheckinTier(props.order.id);
    if (tier === 3) {
      try {
        const { data: fallbackDate } = await supabase.rpc("add_working_days", {
          p_start: new Date().toISOString().slice(0, 10),
          p_n: CHECKIN_TIER3_DEADLINE_WORKING_DAYS,
        });
        deadlineDate = typeof fallbackDate === "string" ? fallbackDate : null;
      } catch (err) {
        captureError(err, { function: "send-order-email", orderId: props.order.id, step: "add_working_days (checkin tier 3 deadline)" });
      }
      if (!deadlineDate) {
        // Defensive fallback if the RPC itself failed -- see
        // addWorkingDaysFallback()'s own comment. A tier-3 "final notice"
        // with no deadline at all defeats the point of the email, so this
        // degrades to an approximate client-side calculation rather than
        // sending one without a date.
        deadlineDate = addWorkingDaysFallback(new Date(), CHECKIN_TIER3_DEADLINE_WORKING_DAYS).toISOString().slice(0, 10);
      }
    }
  }

  const subject =
    props.type === "dispatched"
      ? "A ReturnKits box is on its way to you"
      : tier === 3
        ? props.returnMethod === "collection"
          ? "One last follow-up on your collection"
          : "One last reminder — please send your old device back"
        : props.returnMethod === "collection"
          ? tier === 2
            ? "Still following up on your collection"
            : "We're following up on your collection"
          : tier === 2
            ? "Still outstanding — please send your device back"
            : "Just a reminder — please send your device back";

  // One-shot for dispatched, scoped to this order specifically (not
  // bundle-aware like the customer confirmation -- an employee only cares
  // about their own kit, not any siblings in the same bundle). checkin_sent
  // needs no separate idempotency check here: orders_needing_checkin()'s own
  // 3-day cooldown already prevents this function being invoked again too
  // soon, and it looks at the type across both audiences.
  if (props.type === "dispatched") {
    const { data: existing } = await supabase
      .from("communication_log")
      .select("id")
      .eq("type", "dispatched")
      .eq("audience", "employee")
      .eq("order_id", props.order.id)
      .in("status", ["sent", "delivered"])
      .limit(1);
    if (existing && existing.length > 0) return;
  }

  const { data: suppressed } = await supabase
    .from("suppressed_recipients")
    .select("email")
    .eq("email", recipient.toLowerCase())
    .maybeSingle();

  if (suppressed) {
    await supabase.from("communication_log").insert({
      order_id: props.order.id,
      company_id: props.order.company.id,
      channel: "email",
      type: props.type,
      audience: "employee",
      recipient,
      subject,
      status: "suppressed",
    });
    return;
  }

  const html =
    props.type === "dispatched"
      ? buildEmployeeDispatchedEmail({
          employeeName: props.employeeName,
          companyName: props.order.company.name,
          serviceType: props.order.service_type,
          courier: props.courier ?? "Courier",
          trackingUrl: props.trackingUrl,
          returnMethod: props.returnMethod,
          collectionDate: props.collectionDate,
        })
      : buildEmployeeCheckinSentEmail({
          employeeName: props.employeeName,
          companyName: props.order.company.name,
          returnMethod: props.returnMethod,
          collectionDate: props.collectionDate,
          tier,
          deadlineDate,
        });

  try {
    const resendResp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ from: FROM_ADDRESS, to: recipient, subject, html }),
    });
    const resendBody = await resendResp.json().catch(() => ({}));

    await supabase.from("communication_log").insert({
      order_id: props.order.id,
      company_id: props.order.company.id,
      channel: "email",
      type: props.type,
      audience: "employee",
      recipient,
      subject,
      status: resendResp.ok ? "sent" : "failed",
      provider_message_id: resendResp.ok ? (resendBody.id ?? null) : null,
      error_message: resendResp.ok ? null : JSON.stringify(resendBody).slice(0, 1000),
    });

    if (!resendResp.ok) {
      captureError(new Error(`Resend send failed (employee copy): ${JSON.stringify(resendBody).slice(0, 500)}`), {
        function: "send-order-email",
        orderId: props.order.id,
        type: props.type,
        audience: "employee",
      });
    }
  } catch (err) {
    captureError(err, {
      function: "send-order-email",
      orderId: props.order.id,
      type: props.type,
      audience: "employee",
      step: "employee copy",
    });
  }
}

// ---- Handler --------------------------------------------------------------

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "send-order-email" });
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

  let body: { orderId?: unknown; type?: unknown; estimatedArrivalDate?: unknown };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), { status: 400 });
  }

  const orderId = typeof body.orderId === "string" ? body.orderId : null;
  const type = typeof body.type === "string" ? (body.type as EmailType) : null;
  if (!orderId || !type || !VALID_TYPES.includes(type)) {
    return new Response(JSON.stringify({ error: "orderId and a valid type are required" }), { status: 400 });
  }
  // return_in_transit only: an ISO date the caller (sendcloud-webhook or
  // poll-sendcloud-tracking) resolved from Sendcloud's own
  // expected_delivery_date field on the tracking payload. Optional --
  // falls back to a working-day estimate below when absent.
  const callerEstimatedArrivalDate = typeof body.estimatedArrivalDate === "string" ? body.estimatedArrivalDate : null;

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select(
      `id, reference, bundle_id, service_type, price_ex_vat_pence, created_by, created_at, return_address_id,
       outbound_courier, outbound_tracking_number, outbound_tracking_url,
       return_courier, return_tracking_number, return_tracking_url, employee_id, notify_employee,
       employee_name, employee_email, employee_address_line1, employee_address_line2, employee_city, employee_postcode, employee_country,
       return_method, collection_date, device_reference,
       company:companies(id, name), kit_types(label),
       employees(full_name, email, address_line1, address_line2, city, postcode, country)`,
    )
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) {
    return new Response(JSON.stringify({ error: "Order not found", detail: orderError }), { status: 404 });
  }

  const o = order as unknown as {
    id: string;
    reference: string;
    bundle_id: string | null;
    service_type: string;
    price_ex_vat_pence: number;
    created_by: string | null;
    created_at: string;
    return_address_id: string | null;
    outbound_courier: string | null;
    outbound_tracking_number: string | null;
    outbound_tracking_url: string | null;
    return_courier: string | null;
    return_tracking_number: string | null;
    return_tracking_url: string | null;
    employee_id: string | null;
    notify_employee: boolean;
    employee_name: string | null;
    employee_email: string | null;
    employee_address_line1: string | null;
    employee_address_line2: string | null;
    employee_city: string | null;
    employee_postcode: string | null;
    employee_country: string | null;
    return_method: "drop_off" | "collection";
    collection_date: string | null;
    device_reference: string | null;
    company: { id: string; name: string } | null;
    kit_types: { label: string } | null;
    employees: { full_name: string; email: string | null; address_line1: string | null; address_line2: string | null; city: string | null; postcode: string | null; country: string | null } | null;
  };

  if (!o.company) {
    return new Response(JSON.stringify({ error: "Order has no company" }), { status: 500 });
  }

  const resolvedEmployee = resolveEmployee(o);
  const employeeAddress = resolvedEmployee.addressLine || null;

  // notification_preferences gate (architecture §5: checked before every send)
  const { data: enabled } = await supabase.rpc("notification_enabled", {
    p_company_id: o.company.id,
    p_event_type: type,
  });
  if (enabled === false) {
    return new Response(JSON.stringify({ skipped: true, reason: "notifications disabled for this event type" }), { status: 200 });
  }

  // Recipient: the person who actually placed the order.
  let recipientEmail: string | null = null;
  if (o.created_by) {
    const { data: creator } = await supabase.from("users").select("email").eq("id", o.created_by).maybeSingle();
    recipientEmail = creator?.email ?? null;
  }
  if (!recipientEmail) {
    return new Response(JSON.stringify({ error: "No recipient email found for this order's creator" }), { status: 500 });
  }

  // Bundle-aware order_confirmation: gather sibling orders, dedupe across all of them.
  let siblingOrderIds = [o.id];
  let confirmationLines: ConfirmationLine[] = [
    {
      reference: o.reference,
      kitLabel: o.kit_types?.label ?? "Kit",
      serviceType: o.service_type,
      priceExVatPence: o.price_ex_vat_pence,
      employeeName: resolvedEmployee.name,
      employeeAddress,
    },
  ];
  let bundleReference: string | null = null;
  let returnAddressId: string | null = o.return_address_id;

  if (type === "order_confirmation" && o.bundle_id) {
    const { data: bundle } = await supabase.from("bundles").select("reference").eq("id", o.bundle_id).maybeSingle();
    bundleReference = bundle?.reference ?? null;

    const { data: siblings } = await supabase
      .from("orders")
      .select(
        `id, reference, service_type, price_ex_vat_pence, return_address_id, created_at, kit_types(label),
         employee_name, employee_email, employee_address_line1, employee_address_line2, employee_city, employee_postcode, employee_country,
         employees(full_name, email, address_line1, address_line2, city, postcode, country)`,
      )
      .eq("bundle_id", o.bundle_id)
      .order("created_at", { ascending: true });

    if (siblings && siblings.length > 0) {
      siblingOrderIds = siblings.map((s) => s.id as string);
      confirmationLines = siblings.map((s) => {
        const resolved = resolveEmployee(s as unknown as EmployeeSource);
        return {
          reference: s.reference as string,
          kitLabel: (s as unknown as { kit_types: { label: string } | null }).kit_types?.label ?? "Kit",
          serviceType: s.service_type as string,
          priceExVatPence: s.price_ex_vat_pence as number,
          employeeName: resolved.name,
          employeeAddress: resolved.addressLine || null,
        };
      });
      const withReturnAddress = siblings.find((s) => s.return_address_id);
      returnAddressId = (withReturnAddress?.return_address_id as string | undefined) ?? null;
    }
  }

  // Idempotency: for one-shot types, skip if any sibling order already has a sent/delivered row.
  // return_in_transit is naturally one-shot too -- the dispatched -> in_transit
  // transition it's triggered from only ever fires once per return leg -- but
  // this check is a defensive second layer, same reasoning as the other two.
  if (type === "order_confirmation" || type === "dispatched" || type === "return_in_transit") {
    const { data: existing } = await supabase
      .from("communication_log")
      .select("id")
      .eq("type", type)
      .in("order_id", siblingOrderIds)
      .in("status", ["sent", "delivered"])
      .limit(1);
    if (existing && existing.length > 0) {
      return new Response(JSON.stringify({ skipped: true, reason: "already sent" }), { status: 200 });
    }
  }

  // Resolve the return address to show on the confirmation email: the
  // order's own return_address_id if set, else the company's default.
  let returnAddress: ReturnAddress | null = null;
  if (type === "order_confirmation" && confirmationLines.some((l) => l.serviceType === "return")) {
    if (returnAddressId) {
      const { data: addr } = await supabase
        .from("addresses")
        .select("label, address_line1, address_line2, city, postcode, country")
        .eq("id", returnAddressId)
        .maybeSingle();
      returnAddress = (addr as ReturnAddress | null) ?? null;
    }
    if (!returnAddress) {
      const { data: addr } = await supabase
        .from("addresses")
        .select("label, address_line1, address_line2, city, postcode, country")
        .eq("company_id", o.company.id)
        .eq("is_default_return", true)
        .maybeSingle();
      returnAddress = (addr as ReturnAddress | null) ?? null;
    }
  }

  // ---- Render ----
  let subject: string;
  let html: string;

  if (type === "order_confirmation") {
    const refs = confirmationLines.map((l) => l.reference);
    subject = refs.length > 1 ? `Order confirmed — ${refs[0]} (+${refs.length - 1} more)` : `Order confirmed — ${refs[0]}`;
    html = buildOrderConfirmationEmail({
      companyName: o.company.name,
      createdAt: o.created_at,
      lines: confirmationLines,
      bundleReference,
      returnAddress,
    });
  } else if (type === "dispatched") {
    subject = `Your kit is on its way — ${o.reference}`;

    // No live carrier ETA is available at this point (labels are bought
    // manually in Sendcloud's dashboard -- see CLAUDE.md's "Phase 6 is
    // tracking-only" note -- so there's no synchronous rate/ETA call here).
    // Same fallback pattern as the return_in_transit branch below: a plain
    // working-day estimate off today's date via the add_working_days() SQL
    // helper.
    let estimatedDeliveryDate: string | null = null;
    try {
      const { data: fallbackDate } = await supabase.rpc("add_working_days", {
        p_start: new Date().toISOString().slice(0, 10),
        p_n: DISPATCHED_ESTIMATED_DELIVERY_WORKING_DAYS,
      });
      estimatedDeliveryDate = typeof fallbackDate === "string" ? fallbackDate : null;
    } catch (err) {
      captureError(err, { function: "send-order-email", orderId: o.id, step: "add_working_days fallback (dispatched)" });
      estimatedDeliveryDate = null;
    }

    html = buildDispatchedEmail({
      companyName: o.company.name,
      reference: o.reference,
      kitLabel: o.kit_types?.label ?? "Kit",
      serviceType: o.service_type,
      courier: o.outbound_courier ?? "your courier",
      estimatedDeliveryDate,
      employeeName: resolvedEmployee.name,
      employeeAddress,
      notifyEmployee: o.notify_employee,
      returnMethod: o.return_method,
      collectionDate: o.collection_date,
    });
  } else if (type === "checkin_sent") {
    // Employee-first routing (added 20260827, direct user request): the
    // portal's own communication log already gives the ordering company
    // full visibility into an order's status, so they shouldn't also be
    // emailed about it when the employee -- who has no portal access at
    // all -- can be reminded directly instead. Exactly one audience ever
    // receives a given checkin_sent send: the employee if eligible
    // (notify_employee on + has an email on file), otherwise the customer
    // as a fallback, so an order is never left completely unreminded just
    // because the employee channel isn't available. Computed here first,
    // mirroring sendEmployeeCopy()'s own eligibility check exactly, so the
    // two can never disagree about which audience gets it.
    const employeeEligible = o.notify_employee && !!resolvedEmployee.email;

    if (employeeEligible) {
      await sendEmployeeCopy({
        type,
        order: { id: o.id, service_type: o.service_type, company: o.company },
        employeeEmail: resolvedEmployee.email,
        employeeName: resolvedEmployee.name,
        courier: o.outbound_courier,
        trackingUrl: o.outbound_tracking_url,
        notifyEmployee: o.notify_employee,
        returnMethod: o.return_method,
        collectionDate: o.collection_date,
      });
      return new Response(JSON.stringify({ skipped: true, reason: "employee eligible, customer copy suppressed" }), { status: 200 });
    }

    // orders_needing_checkin() (20260820 restructure) now only surfaces a
    // collection-method return here once its collection_date has passed
    // without the leg moving to in_transit/completed -- so by the time
    // this branch runs, o.return_method === "collection" always means
    // "this looks like a missed collection," never "collection is still
    // pending." The subject and template both reflect that directly.
    // Tier (added 20260826, made audience-agnostic 20260827): counts prior
    // sent/delivered checkin_sent rows for this order -- see
    // computeCheckinTier()'s own comment. Tier 3 gets a unified subject
    // regardless of return_method (direct requirement: "both order types"
    // share the same tier-3 copy), unlike tiers 1/2 below, which still
    // branch on drop-off vs collection.
    const customerTier = await computeCheckinTier(o.id);
    subject =
      customerTier === 3
        ? `Still outstanding — ${resolvedEmployee.name ?? "the recipient"}'s device`
        : o.return_method === "collection"
          ? `Collection check — ${o.reference}`
          : `Reminder: please send your kit back — ${o.reference}`;
    // Reaching this point already proves !employeeEligible, so
    // employeeStatus can only ever be notify_off or no_email here -- see
    // CheckinSentEmployeeStatus's own comment for why "notified" was
    // removed as a possible value entirely rather than left theoretically
    // reachable.
    const employeeStatus: CheckinSentEmployeeStatus = !o.notify_employee ? "notify_off" : "no_email";
    html = buildCheckinSentEmail({
      companyName: o.company.name,
      reference: o.reference,
      kitLabel: o.kit_types?.label ?? "Kit",
      deviceReference: o.device_reference,
      employeeName: resolvedEmployee.name,
      employeeStatus,
      returnMethod: o.return_method,
      collectionDate: o.collection_date,
      tier: customerTier,
    });
  } else {
    // return_in_transit: prefer the caller's resolved date (sourced from
    // Sendcloud's expected_delivery_date on the tracking payload), fall
    // back to a working-day estimate off today's date when the caller
    // didn't have one to pass through.
    let estimatedArrivalDate = callerEstimatedArrivalDate;
    if (!estimatedArrivalDate) {
      try {
        const { data: fallbackDate } = await supabase.rpc("add_working_days", {
          p_start: new Date().toISOString().slice(0, 10),
          p_n: RETURN_IN_TRANSIT_FALLBACK_WORKING_DAYS,
        });
        estimatedArrivalDate = typeof fallbackDate === "string" ? fallbackDate : null;
      } catch (err) {
        captureError(err, { function: "send-order-email", orderId: o.id, step: "add_working_days fallback" });
        estimatedArrivalDate = null;
      }
    }

    subject = `Return in progress — ${o.reference}`;
    html = buildReturnInTransitEmail({
      companyName: o.company.name,
      reference: o.reference,
      kitLabel: o.kit_types?.label ?? "Kit",
      courier: o.return_courier ?? "Courier",
      trackingNumber: o.return_tracking_number ?? "—",
      trackingUrl: o.return_tracking_url,
      estimatedArrivalDate,
    });
  }

  // Suppression check (Phase 5: resend-webhook populates this on hard
  // bounce / spam complaint). Checked last, right before the network call,
  // so a recipient suppressed mid-request (unlikely, but the check is
  // cheap) still gets caught.
  const { data: suppressed } = await supabase
    .from("suppressed_recipients")
    .select("email")
    .eq("email", recipientEmail.toLowerCase())
    .maybeSingle();

  if (suppressed) {
    await supabase.from("communication_log").insert({
      order_id: o.id,
      company_id: o.company.id,
      channel: "email",
      type,
      audience: "customer",
      recipient: recipientEmail,
      subject,
      status: "suppressed",
    });
    return new Response(JSON.stringify({ skipped: true, reason: "recipient is suppressed" }), { status: 200 });
  }

  // ---- Send via Resend ----
  const resendResp = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: FROM_ADDRESS,
      to: recipientEmail,
      subject,
      html,
    }),
  });

  const resendBody = await resendResp.json().catch(() => ({}));

  // Employee-facing copy (dispatched/checkin_sent only) -- independent of
  // whether the customer send above succeeded or failed.
  await sendEmployeeCopy({
    type,
    order: { id: o.id, service_type: o.service_type, company: o.company },
    employeeEmail: resolvedEmployee.email,
    employeeName: resolvedEmployee.name,
    courier: o.outbound_courier,
    trackingUrl: o.outbound_tracking_url,
    notifyEmployee: o.notify_employee,
    returnMethod: o.return_method,
    collectionDate: o.collection_date,
  });

  if (!resendResp.ok) {
    await supabase.from("communication_log").insert({
      order_id: o.id,
      company_id: o.company.id,
      channel: "email",
      type,
      audience: "customer",
      recipient: recipientEmail,
      subject,
      status: "failed",
      error_message: JSON.stringify(resendBody).slice(0, 1000),
    });
    captureError(new Error(`Resend send failed: ${JSON.stringify(resendBody).slice(0, 500)}`), {
      function: "send-order-email",
      orderId: o.id,
      type,
    });
    return new Response(JSON.stringify({ error: "Resend send failed", detail: resendBody }), { status: 502 });
  }

  await supabase.from("communication_log").insert({
    order_id: o.id,
    company_id: o.company.id,
    channel: "email",
    type,
    audience: "customer",
    recipient: recipientEmail,
    subject,
    status: "sent",
    provider_message_id: resendBody.id ?? null,
  });

  return new Response(JSON.stringify({ sent: true, messageId: resendBody.id ?? null }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}
