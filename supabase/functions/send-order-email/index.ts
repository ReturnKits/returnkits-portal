// supabase/functions/send-order-email/index.ts
//
// Hand-written per CLAUDE.md. Renders one of the four launch-critical
// transactional emails (architecture §21) and sends it via Resend. Called
// two ways:
//   1. From Postgres triggers on `orders` (payment_status -> paid,
//      fulfilment_status -> dispatched), via pg_net.http_post -- see the
//      Phase 5 trigger migration.
//   2. Later, from the pg_cron check-in job (checkin_sent / checkin_received).
//
// Templates: plain typed TypeScript functions building HTML strings, NOT
// @react-email/components + @react-email/render as architecture §21
// originally specified. Deliberate substitution, same category as pdf-lib
// over React-PDF elsewhere in this codebase: a live test (Phase 5, this
// session) showed React's server-render path crashing at boot in this
// project's Deno edge runtime (500, no captured log line -- consistent with
// an npm import failure during module init, before any request-level code
// runs). The architectural INTENT survives -- typed functions taking typed
// props, one place per template, no copy-pasted markup -- only the specific
// rendering mechanism changes.
//
// Visual style matched against the Base44 prototype's confirmation email
// (user-supplied reference screenshot) rather than invented from scratch:
// wordmark header, order meta line, itemised pricing, a "Return destination"
// block for return orders, numbered "what happens next" steps.
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
// once the cron job (Phase 5, later) is built.

import { createClient } from "jsr:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const resendApiKey = Deno.env.get("RESEND_API_KEY");
const FROM_ADDRESS = "ReturnKits <noreply@mail.returnkits.com>";

if (!supabaseUrl || !serviceRoleKey || !resendApiKey) {
  console.error("send-order-email: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / RESEND_API_KEY");
}

const supabase = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");

type EmailType = "order_confirmation" | "dispatched" | "checkin_sent" | "checkin_received";

const VALID_TYPES: EmailType[] = ["order_confirmation", "dispatched", "checkin_sent", "checkin_received"];

function pence(n: number): string {
  return `£${(n / 100).toFixed(2)}`;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });
}

// ---- Shared layout ----------------------------------------------------

// Hosted in the public brand-assets Storage bucket (uploaded once via the
// one-off seed-brand-logo function) rather than the text wordmark this
// replaced -- the user supplied the actual logo file to match.
const LOGO_URL = "https://pzewknoohcqdqrrhwqrs.supabase.co/storage/v1/object/public/brand-assets/returnkits-wordmark.png";
const LOGO_IMG = `<img src="${LOGO_URL}" width="180" height="37" alt="ReturnKits" style="display:block;border:0;outline:none;text-decoration:none;height:37px;width:180px;" />`;

function layout(previewText: string, bodyHtml: string): string {
  return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>${escapeHtml(previewText)}</title>
</head>
<body style="background-color:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;margin:0;padding:24px 0;">
  <div style="display:none;max-height:0;overflow:hidden;">${escapeHtml(previewText)}</div>
  <div style="background-color:#ffffff;border-radius:12px;padding:32px;max-width:520px;margin:0 auto;border:1px solid #e5e7eb;">
    <div style="margin:0 0 28px;">${LOGO_IMG}</div>
    ${bodyHtml}
    <hr style="border-color:#e5e7eb;border-style:solid;border-width:1px 0 0;margin:28px 0 16px;" />
    <div style="margin:0 0 4px;">${LOGO_IMG}</div>
    <p style="font-size:12px;color:#9ca3af;margin:8px 0 8px;">
      <a href="https://returnkits.com" style="color:#9ca3af;text-decoration:none;">returnkits.com</a>
      &nbsp;·&nbsp;
      <a href="mailto:support@returnkits.com" style="color:#9ca3af;text-decoration:none;">support@returnkits.com</a>
    </p>
    <p style="font-size:11px;color:#c4c8ce;margin:0;">UK Nationwide IT Asset Recovery. You're receiving this because you placed an order with ReturnKits.</p>
  </div>
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

function numberedSteps(steps: string[]): string {
  const rows = steps
    .map(
      (step, i) => `<tr>
        <td style="width:24px;vertical-align:top;padding:6px 8px 6px 0;">
          <span style="display:inline-block;width:20px;height:20px;line-height:20px;border-radius:50%;background:#dbeafe;color:#2563eb;font-size:12px;font-weight:700;text-align:center;">${i + 1}</span>
        </td>
        <td style="padding:6px 0;font-size:14px;color:#374151;">${escapeHtml(step)}</td>
      </tr>`,
    )
    .join("");
  return `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;margin:0 0 20px;">${rows}</table>`;
}

// ---- Order confirmation (bundle-aware) --------------------------------

type ConfirmationLine = { reference: string; kitLabel: string; serviceType: string; priceExVatPence: number };
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
  const steps: string[] = ["We prepare and dispatch your kit"];
  if (hasReturn) steps.push("Recipient packs the device securely", "Device returned via prepaid tracked label");
  if (hasShipToEmployee) steps.push("New starter receives and sets up their kit");

  // Single flowing address line ("66 Sandhill Oval, Leeds, LS17 8EE") to
  // match the reference design, rather than street on its own line and
  // city/postcode on the next.
  const addressLine = props.returnAddress
    ? [props.returnAddress.address_line1, props.returnAddress.address_line2, `${props.returnAddress.city}, ${props.returnAddress.postcode}`]
        .filter(Boolean)
        .map((part) => escapeHtml(part as string))
        .join(", ")
    : "";

  const returnBlock = props.returnAddress
    ? `<h2 style="font-size:14px;font-weight:700;color:#111827;margin:24px 0 8px;">Return destination</h2>
       <p style="font-size:14px;color:#111827;margin:0 0 2px;font-weight:600;">${escapeHtml(props.returnAddress.label ?? props.companyName)}</p>
       <p style="font-size:14px;color:#374151;margin:0;line-height:20px;">${addressLine}</p>`
    : "";

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
    <h2 style="font-size:14px;font-weight:700;color:#111827;margin:24px 0 12px;">What happens next</h2>
    ${numberedSteps(steps)}
    <p style="font-size:13px;line-height:20px;color:#6b7280;margin:20px 0 0;">Questions about your order? Just reply to this email, or reach us at <a href="mailto:support@returnkits.com" style="color:#2563eb;text-decoration:none;">support@returnkits.com</a>.</p>
  `;

  return layout(`Order confirmed — ${primaryRef}${moreCount > 0 ? ` (+${moreCount} more)` : ""}`, body);
}

// ---- Dispatched ---------------------------------------------------------

function buildDispatchedEmail(props: { companyName: string; reference: string; kitLabel: string; courier: string; trackingNumber: string; trackingUrl: string | null }): string {
  const trackingBlock = props.trackingUrl
    ? `<div style="margin:0 0 12px;">
        <p style="font-size:12px;color:#6b7280;margin:0;">Tracking number</p>
        <p style="font-size:14px;font-weight:600;margin:0;"><a href="${escapeHtml(props.trackingUrl)}" style="color:#2563eb;">${escapeHtml(props.trackingNumber)}</a></p>
      </div>`
    : field("Tracking number", props.trackingNumber);

  const body = `
    <p style="font-size:12px;color:#9ca3af;margin:0 0 4px;">Order ${escapeHtml(props.reference)}</p>
    <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">Your kit is on its way</h1>
    <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 20px;">${escapeHtml(props.kitLabel)} for ${escapeHtml(props.companyName)} has been dispatched.</p>
    ${field("Courier", props.courier)}
    ${trackingBlock}
  `;

  return layout(`On its way — ${props.reference}`, body);
}

// ---- Check-in: have you sent it back? (return orders) -------------------

function buildCheckinSentEmail(props: { companyName: string; reference: string; kitLabel: string }): string {
  const body = `
    <p style="font-size:12px;color:#9ca3af;margin:0 0 4px;">Order ${escapeHtml(props.reference)}</p>
    <h1 style="font-size:22px;font-weight:700;color:#111827;margin:0 0 16px;">Just checking in</h1>
    <p style="font-size:14px;line-height:22px;color:#374151;margin:0 0 12px;">
      We haven't heard back on ${escapeHtml(props.kitLabel)} for ${escapeHtml(props.companyName)} yet.
      If it's already on its way back to us, you can confirm this in your portal so we can stop chasing.
      If it hasn't been posted yet, no rush — just let us know if anything's blocking it.
    </p>
  `;
  return layout(`Have you sent your kit back? — ${props.reference}`, body);
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

// ---- Handler --------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (authHeader !== `Bearer ${serviceRoleKey}`) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  let body: { orderId?: unknown; type?: unknown };
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

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select(
      `id, reference, bundle_id, service_type, price_ex_vat_pence, created_by, created_at, return_address_id,
       outbound_courier, outbound_tracking_number, outbound_tracking_url,
       company:companies(id, name), kit_types(label)`,
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
    company: { id: string; name: string } | null;
    kit_types: { label: string } | null;
  };

  if (!o.company) {
    return new Response(JSON.stringify({ error: "Order has no company" }), { status: 500 });
  }

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
    { reference: o.reference, kitLabel: o.kit_types?.label ?? "Kit", serviceType: o.service_type, priceExVatPence: o.price_ex_vat_pence },
  ];
  let bundleReference: string | null = null;
  let returnAddressId: string | null = o.return_address_id;

  if (type === "order_confirmation" && o.bundle_id) {
    const { data: bundle } = await supabase.from("bundles").select("reference").eq("id", o.bundle_id).maybeSingle();
    bundleReference = bundle?.reference ?? null;

    const { data: siblings } = await supabase
      .from("orders")
      .select("id, reference, service_type, price_ex_vat_pence, return_address_id, created_at, kit_types(label)")
      .eq("bundle_id", o.bundle_id)
      .order("created_at", { ascending: true });

    if (siblings && siblings.length > 0) {
      siblingOrderIds = siblings.map((s) => s.id as string);
      confirmationLines = siblings.map((s) => ({
        reference: s.reference as string,
        kitLabel: (s as unknown as { kit_types: { label: string } | null }).kit_types?.label ?? "Kit",
        serviceType: s.service_type as string,
        priceExVatPence: s.price_ex_vat_pence as number,
      }));
      const withReturnAddress = siblings.find((s) => s.return_address_id);
      returnAddressId = (withReturnAddress?.return_address_id as string | undefined) ?? null;
    }
  }

  // Idempotency: for one-shot types, skip if any sibling order already has a sent/delivered row.
  if (type === "order_confirmation" || type === "dispatched") {
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
    html = buildDispatchedEmail({
      companyName: o.company.name,
      reference: o.reference,
      kitLabel: o.kit_types?.label ?? "Kit",
      courier: o.outbound_courier ?? "Courier",
      trackingNumber: o.outbound_tracking_number ?? "—",
      trackingUrl: o.outbound_tracking_url,
    });
  } else if (type === "checkin_sent") {
    subject = `Have you sent your kit back? — ${o.reference}`;
    html = buildCheckinSentEmail({ companyName: o.company.name, reference: o.reference, kitLabel: o.kit_types?.label ?? "Kit" });
  } else {
    subject = `Has your kit arrived? — ${o.reference}`;
    html = buildCheckinReceivedEmail({ companyName: o.company.name, reference: o.reference, kitLabel: o.kit_types?.label ?? "Kit" });
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
});
