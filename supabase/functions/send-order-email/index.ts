// supabase/functions/send-order-email/index.ts
//
// Hand-written per CLAUDE.md. Renders one of the transactional emails
// (architecture §21) and sends it via Resend. Called two ways:
//   1. From Postgres triggers on `orders` (payment_status -> paid,
//      fulfilment_status -> dispatched), via pg_net.http_post -- see the
//      Phase 5 trigger migration.
//   2. From the pg_cron check-in job (checkin_sent / checkin_received).
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
// but checkin_* are expected to legitimately repeat over an order's life
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

if (!supabaseUrl || !serviceRoleKey || !resendApiKey) {
  console.error("send-order-email: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / RESEND_API_KEY");
}

const supabase = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");

type EmailType = "order_confirmation" | "dispatched" | "checkin_sent" | "checkin_received" | "return_in_transit";

const VALID_TYPES: EmailType[] = ["order_confirmation", "dispatched", "checkin_sent", "checkin_received", "return_in_transit"];

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
  const vat = Math.round(totalExVat * 0.2);
  const totalIncVat = totalExVat + vat;

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
      <tr><td style="padding:10px 0 4px;font-size:13px;color:#6b7280;">VAT (20%)</td><td style="padding:10px 0 4px;font-size:13px;color:#111827;text-align:right;">${pence(vat)}</td></tr>
      <tr><td style="padding:6px 0 0;font-size:15px;color:#111827;font-weight:700;">Total paid</td><td style="padding:6px 0 0;font-size:15px;color:#111827;font-weight:700;text-align:right;">${pence(totalIncVat)}</td></tr>
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

function buildDispatchedEmail(props: {
  companyName: string;
  reference: string;
  kitLabel: string;
  serviceType: string;
  courier: string;
  estimatedDeliveryDate: string | null;
  employeeName: string | null;
  employeeAddress: string | null;
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
  // promise. `props.courier` is still passed through and used below, in the
  // return-order "sending it back" instructions only -- it's no longer
  // displayed as its own field.
  const etaLine = props.estimatedDeliveryDate
    ? `<p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 20px;">Estimated delivery: around ${escapeHtml(formatDate(props.estimatedDeliveryDate))}. Courier estimates can shift by a day or so.</p>`
    : "";

  const guidanceUrl = courierGuidanceUrl(props.courier);

  // The box that's just gone out already contains a prepaid label for the
  // NEXT leg -- posting the old device back to us (return orders) or, for
  // ship-to-new-employee orders, there's nothing further for the recipient
  // to post. Only return orders get the "how to send it back" instructions.
  const nextStepsBlock = isReturn
    ? `<h2 style="font-size:14px;font-weight:700;color:#111827;margin:24px 0 12px;">Sending the device back</h2>
       ${numberedSteps([
         "Pack the device securely using the materials enclosed in the kit",
         "Attach the prepaid return label that's already inside the box — no need to print anything",
         guidanceUrl
           ? `Drop it off with ${escapeHtml(props.courier)}${props.courier.toLowerCase().includes("dpd") ? " (use the link below to arrange a collection)" : " (use the link below to find a drop-off point)"}`
           : `Drop it off with ${escapeHtml(props.courier)}`,
       ])}
       ${guidanceUrl ? `<p style="margin:0 0 20px;"><a href="${escapeHtml(guidanceUrl)}" style="color:#2563eb;font-size:13px;text-decoration:none;font-weight:600;">${props.courier.toLowerCase().includes("dpd") ? "Arrange a DPD collection" : "Find a drop-off point"} →</a></p>`
         : ""}`
    : `<p style="font-size:13px;line-height:20px;color:#6b7280;margin:20px 0 0;">Nothing further to do on your end once it arrives with the new starter — we'll follow up to confirm.</p>`;

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
type CheckinSentEmployeeStatus = "notified" | "notify_off" | "no_email";

function buildCheckinSentEmail(props: {
  companyName: string;
  reference: string;
  kitLabel: string;
  employeeName: string | null;
  employeeStatus: CheckinSentEmployeeStatus;
}): string {
  const employeeDisplay = escapeHtml(props.employeeName ?? "the recipient");
  const baseLine = `We haven't seen ${escapeHtml(props.kitLabel)} for ${escapeHtml(props.companyName)} come back to us yet.`;

  let followUp: string;
  if (props.employeeStatus === "notified") {
    followUp = `We've also sent ${employeeDisplay} a reminder.`;
  } else if (props.employeeStatus === "notify_off") {
    followUp = `You may want to follow up with ${employeeDisplay} directly — employee notifications weren't turned on for this order.`;
  } else {
    followUp = `You may want to follow up with ${employeeDisplay} directly — we don't have an email on file for them.`;
  }

  const body = `
    <p style="font-size:12px;color:#9ca3af;margin:0 0 4px;">Order ${escapeHtml(props.reference)}</p>
    <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">Just a reminder</h1>
    <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
      ${baseLine} ${followUp} We'll take it from there once it arrives — no need to let us know.
    </p>
  `;
  return layout(`Reminder: please send your kit back — ${props.reference}`, body);
}

// ---- Check-in: has it arrived? (ship-to-new-employee orders) ------------

function buildCheckinReceivedEmail(props: { companyName: string; reference: string; kitLabel: string }): string {
  const body = `
    <p style="font-size:12px;color:#9ca3af;margin:0 0 4px;">Order ${escapeHtml(props.reference)}</p>
    <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">Just checking in</h1>
    <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
      ${escapeHtml(props.kitLabel)} for ${escapeHtml(props.companyName)} was dispatched a little while ago.
      Could you confirm in your portal once it's arrived with the new starter? That closes the order out on our end.
    </p>
  `;
  return layout(`Has the kit arrived? — ${props.reference}`, body);
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
// order_confirmation / checkin_received.

function buildEmployeeDispatchedEmail(props: {
  employeeName: string;
  companyName: string;
  serviceType: string;
  courier: string;
  trackingUrl: string | null;
}): string {
  const isReturn = props.serviceType === "return";

  const whatNext = isReturn
    ? `<p style="font-size:14px;line-height:22px;color:#374151;margin:16px 0 0;">
         Once it arrives, please use it to post your old device back — everything you need, including a
         prepaid return label, is already inside the box. No need to let anyone know once it's done.
       </p>`
    : `<p style="font-size:14px;line-height:22px;color:#374151;margin:16px 0 0;">
         Nothing else to do once it arrives — it's ready to use.
       </p>`;

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

function buildEmployeeCheckinSentEmail(props: { employeeName: string }): string {
  const body = `
    <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">Just a reminder</h1>
    <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
      Hi ${escapeHtml(props.employeeName)}, when you get a chance, please pop your old device in the post
      using the prepaid label included in the box we sent you. No need to let anyone know once it's done.
    </p>
  `;
  return layout("Just a reminder — please post your device back", body);
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
  const subject =
    props.type === "dispatched"
      ? "A ReturnKits box is on its way to you"
      : "Just a reminder — please post your device back";

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
        })
      : buildEmployeeCheckinSentEmail({ employeeName: props.employeeName });

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
    });
  } else if (type === "checkin_sent") {
    subject = `Reminder: please send your kit back — ${o.reference}`;
    // Mirrors sendEmployeeCopy()'s own eligibility check (notify_employee +
    // employee has an email) but doesn't wait for that send to actually
    // happen -- this only needs to know whether the system is configured to
    // also nudge the employee, not confirm delivery, consistent with how
    // this codebase doesn't retroactively reconcile customer-facing copy
    // against downstream delivery outcomes anywhere else either.
    const employeeStatus: CheckinSentEmployeeStatus = !o.notify_employee
      ? "notify_off"
      : resolvedEmployee.email
        ? "notified"
        : "no_email";
    html = buildCheckinSentEmail({
      companyName: o.company.name,
      reference: o.reference,
      kitLabel: o.kit_types?.label ?? "Kit",
      employeeName: resolvedEmployee.name,
      employeeStatus,
    });
  } else if (type === "checkin_received") {
    subject = `Has your kit arrived? — ${o.reference}`;
    html = buildCheckinReceivedEmail({ companyName: o.company.name, reference: o.reference, kitLabel: o.kit_types?.label ?? "Kit" });
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
