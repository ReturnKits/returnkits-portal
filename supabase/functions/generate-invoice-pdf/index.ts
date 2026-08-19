// supabase/functions/generate-invoice-pdf/index.ts
//
// Hand-written per CLAUDE.md ("Money & concurrency ... hand-written, never
// generated"). Lets a signed-in customer download a real invoice PDF
// for their own company's invoice, from the portal. Added 20260818.
//
// Two separate trust boundaries, deliberately not mixed:
//   - READING the invoice/orders/credit_ledger rows goes through a client
//     built from the CALLER'S OWN JWT (not service_role), the same pattern
//     create-checkout-session and export-orders-email already established
//     -- so invoices_select RLS (own company, or internal) is the one and
//     only thing deciding whether this invoice is even visible. No company
//     check is duplicated in this function's own code.
//   - WRITING the rendered PDF to Storage and creating the signed URL uses
//     service_role, same as generate-print-pack -- the 'invoices' bucket
//     (20260818230000_invoice_pdf_storage_bucket.sql) has no
//     authenticated/anon storage policies at all, exactly like
//     'print-packs', so nothing but this function's service_role client
//     ever touches it directly.
//
// Renders with pdf-lib, not Puppeteer/React-PDF, for the same reason
// generate-print-pack does: neither runs in the Deno Edge Function sandbox.
//
// Invoice numbering: this PDF uses ONLY ReturnKits' own invoices.invoice_number
// (the strictly gapless Postgres sequence -- see CLAUDE.md). Stripe's own
// Invoicing feature (`invoice_creation` on Checkout Sessions) is deliberately
// never enabled anywhere in this codebase -- turning it on would make Stripe
// assign a second, independent invoice number to the same purchase, which
// the user explicitly confirmed 20260818 is not acceptable ("i cant have 2
// separate invoice numbers"). Stripe's own automatic payment receipts
// (Dashboard > Settings > Business > Customer emails) stay on as a normal
// convenience, but a plain Stripe receipt has no formal invoice number of
// its own unless invoice_creation is enabled, so there's no numbering
// conflict from those either. The `stripe_payment_intent_id` shown on this
// PDF is a payment reference for reconciliation only, never presented as an
// invoice number.
//
// VAT (added 20260818, same day as the "not VAT-registered" migration):
// ReturnKits is not VAT-registered, so vat_rate is 0% everywhere and every
// invoice's subtotal_ex_vat_pence and total_inc_vat_pence are always equal.
// Per the user's explicit request to strip VAT language out of the portal
// entirely ("i can see VAt on there, thought we took VAt out ?" -> "yes"),
// this PDF no longer renders a Subtotal/VAT breakdown or an "(ex VAT)"
// column header -- just a plain "Amount" column and a single "Total" row.
//
// Credit-purchase invoices (20260818): a credit purchase never creates an
// `orders` row (record_credit_purchase only touches invoices + credit_ledger),
// so this function ALSO checks credit_ledger.invoice_id -- the actual link
// for that case -- and renders "N × {kit type} credits" as the line item.
// create-credit-checkout-session only ever creates a Checkout Session for
// ONE kit type at a time (a single Stripe line item), so a credit invoice
// always has exactly one `credit_ledger` purchase row; that row's own
// quantity has no separately-stored unit price (only invoice-level
// subtotal/vat/total are persisted), so the single credit line is priced at
// the invoice's own subtotal_ex_vat_pence -- correct precisely because
// there is never more than one such row per credit invoice. An order
// invoice and a credit invoice are never the same row (record_stripe_payment
// and record_credit_purchase each insert their own invoices row), so orders
// and credit_ledger lines are never mixed on one PDF in practice.
//
// Storage: private 'invoices' bucket, signed URL only, same TTL as
// generate-print-pack.
//
// Required secrets: SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY
// are provided automatically.

import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";
import { createClient } from "jsr:@supabase/supabase-js@2";

// Inlined from ../_shared/sentry.ts -- same MCP-deploy bundling issue noted
// in send-order-email/generate-print-pack/export-orders-email.
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
    "generate-invoice-pdf: missing SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY",
  );
}

const SIGNED_URL_TTL_SECONDS = 60 * 60; // 1 hour, same as generate-print-pack.

function formatAddress(parts: Array<string | null | undefined>): string[] {
  return parts.filter((part): part is string => Boolean(part && part.trim()));
}

function formatPence(pence: number): string {
  return `£${(pence / 100).toFixed(2)}`;
}

function invoiceNumber(value: number): string {
  return `#${String(value).padStart(6, "0")}`;
}

type InvoiceRow = {
  id: string;
  invoice_number: number;
  issued_at: string;
  subtotal_ex_vat_pence: number;
  vat_pence: number;
  total_inc_vat_pence: number;
  status: string;
  stripe_payment_intent_id: string | null;
  stripe_checkout_session_id: string | null;
};

type CompanyRow = {
  name: string;
  billing_email: string | null;
  address_line1: string | null;
  address_line2: string | null;
  city: string | null;
  postcode: string | null;
  country: string | null;
};

type OrderLineRow = {
  reference: string;
  price_ex_vat_pence: number;
  cover_tier_id: string | null;
  cover_price_ex_vat_pence: number | null;
  kit_types: { label: string } | null;
  cover_tiers: { label: string } | null;
};

type CreditLineRow = {
  quantity: number;
  kit_types: { label: string } | null;
};

Deno.serve(async (req: Request) => {
  try {
    return await handleRequest(req);
  } catch (err) {
    captureError(err, { function: "generate-invoice-pdf" });
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

  let body: { invoiceId?: unknown };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const invoiceId = typeof body.invoiceId === "string" ? body.invoiceId : null;
  if (!invoiceId) {
    return new Response(JSON.stringify({ error: "invoiceId is required" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Caller-scoped client -- RLS decides whether this invoice, and which
  // company's orders/credit_ledger rows, are even visible.
  const userClient = createClient(supabaseUrl ?? "", anonKey ?? "", {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: invoice, error: invoiceError } = await userClient
    .from("invoices")
    .select(
      "id, invoice_number, issued_at, subtotal_ex_vat_pence, vat_pence, total_inc_vat_pence, status, stripe_payment_intent_id, stripe_checkout_session_id",
    )
    .eq("id", invoiceId)
    .maybeSingle();

  if (invoiceError) {
    captureError(invoiceError, { function: "generate-invoice-pdf", step: "invoice lookup" });
    return new Response(JSON.stringify({ error: "Could not look up invoice" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  if (!invoice) {
    return new Response(JSON.stringify({ error: "Invoice not found" }), {
      status: 404,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  const invoiceRow = invoice as InvoiceRow;

  // Own-company row, per companies_select RLS -- same pattern
  // create-checkout-session already uses for "who am I billing this to".
  const { data: company } = await userClient
    .from("companies")
    .select("name, billing_email, address_line1, address_line2, city, postcode, country")
    .maybeSingle();
  const companyRow = company as CompanyRow | null;

  const { data: orderLines, error: ordersError } = await userClient
    .from("orders")
    .select(
      "reference, price_ex_vat_pence, cover_tier_id, cover_price_ex_vat_pence, kit_types(label), cover_tiers(label)",
    )
    .eq("invoice_id", invoiceId)
    .order("reference", { ascending: true });

  if (ordersError) {
    captureError(ordersError, { function: "generate-invoice-pdf", step: "orders lookup", invoiceId });
    return new Response(JSON.stringify({ error: "Could not look up invoice line items" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const { data: creditLines, error: creditError } = await userClient
    .from("credit_ledger")
    .select("quantity, kit_types(label)")
    .eq("invoice_id", invoiceId)
    .eq("transaction_type", "purchase");

  if (creditError) {
    captureError(creditError, { function: "generate-invoice-pdf", step: "credit_ledger lookup", invoiceId });
    return new Response(JSON.stringify({ error: "Could not look up invoice line items" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // ---- Build line items ----
  type Line = { description: string; amountPence: number };
  const lines: Line[] = [];

  for (const order of (orderLines ?? []) as OrderLineRow[]) {
    lines.push({
      description: `${order.kit_types?.label ?? "Kit"} — ${order.reference}`,
      amountPence: order.price_ex_vat_pence,
    });
    if (order.cover_tier_id && order.cover_price_ex_vat_pence != null) {
      lines.push({
        description: order.cover_tiers?.label ?? "Enhanced Cover",
        amountPence: order.cover_price_ex_vat_pence,
      });
    }
  }

  // A credit invoice always has exactly one `purchase` row (see header
  // comment) -- priced at the invoice's own subtotal since no per-line
  // price is stored on credit_ledger.
  for (const credit of (creditLines ?? []) as CreditLineRow[]) {
    const label = credit.kit_types?.label ?? "Kit";
    const qty = credit.quantity;
    lines.push({
      description: `${qty} × ${label} credit${qty === 1 ? "" : "s"}`,
      amountPence: invoiceRow.subtotal_ex_vat_pence,
    });
  }

  if (lines.length === 0) {
    // Shouldn't happen for any real invoice, but render something honest
    // rather than a blank line-items section.
    lines.push({ description: "Payment to ReturnKits", amountPence: invoiceRow.subtotal_ex_vat_pence });
  }

  // ---- Render the PDF ----
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([595.28, 841.89]); // A4 in points
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);

  let y = 780;
  const left = 56;
  const right = 539.28;

  const drawLine = (
    text: string,
    opts: { size?: number; useBold?: boolean; gap?: number; color?: [number, number, number]; align?: "left" | "right" } = {},
  ) => {
    const { size = 11, useBold = false, gap = 18, color = [0, 0, 0], align = "left" } = opts;
    const usedFont = useBold ? bold : font;
    const width = usedFont.widthOfTextAtSize(text, size);
    const x = align === "right" ? right - width : left;
    page.drawText(text, { x, y, size, font: usedFont, color: rgb(color[0], color[1], color[2]) });
    y -= gap;
  };

  const drawRow = (labelText: string, value: string, opts: { useBold?: boolean; size?: number; gap?: number } = {}) => {
    const { useBold = false, size = 11, gap = 18 } = opts;
    const usedFont = useBold ? bold : font;
    page.drawText(labelText, { x: left, y, size, font: usedFont, color: rgb(0, 0, 0) });
    const width = usedFont.widthOfTextAtSize(value, size);
    page.drawText(value, { x: right - width, y, size, font: usedFont, color: rgb(0, 0, 0) });
    y -= gap;
  };

  drawLine("ReturnKits", { size: 22, useBold: true, gap: 26 });
  drawLine("UK IT asset recovery & reverse logistics", { size: 10, gap: 30, color: [0.4, 0.4, 0.4] });

  drawLine(`Invoice ${invoiceNumber(invoiceRow.invoice_number)}`, { size: 16, useBold: true, gap: 22 });
  drawLine(`Issued ${new Date(invoiceRow.issued_at).toLocaleDateString("en-GB")}`, { size: 10, gap: 14, color: [0.4, 0.4, 0.4] });
  drawLine(`Status: ${invoiceRow.status === "voided" ? "Voided" : "Paid"}`, { size: 10, gap: 26, color: [0.4, 0.4, 0.4] });

  if (companyRow) {
    drawLine("Bill to", { size: 10, useBold: true, gap: 16, color: [0.4, 0.4, 0.4] });
    const billLines = formatAddress([
      companyRow.name,
      companyRow.address_line1,
      companyRow.address_line2,
      companyRow.city,
      companyRow.postcode,
      companyRow.country,
    ]);
    for (const line of billLines) drawLine(line, { size: 11, gap: 15 });
  }
  y -= 20;

  // Line items header
  drawRow("Description", "Amount", { useBold: true, size: 10, gap: 8 });
  y -= 6;
  page.drawLine({ start: { x: left, y }, end: { x: right, y }, thickness: 0.5, color: rgb(0.8, 0.8, 0.8) });
  y -= 14;

  for (const line of lines) {
    drawRow(line.description, formatPence(line.amountPence), { size: 11, gap: 18 });
  }

  y -= 6;
  page.drawLine({ start: { x: left, y }, end: { x: right, y }, thickness: 0.5, color: rgb(0.8, 0.8, 0.8) });
  y -= 20;

  // ReturnKits is not VAT-registered (0% rate, see CLAUDE.md "not
  // VAT-registered" locked decision) -- subtotal_ex_vat_pence and
  // total_inc_vat_pence are always equal, so this renders a single Total
  // line rather than a Subtotal/VAT breakdown that would just show £0.00 VAT.
  drawRow("Total", formatPence(invoiceRow.total_inc_vat_pence), { useBold: true, size: 13, gap: 24 });

  y -= 10;
  drawLine(
    `Payment reference: ${invoiceRow.stripe_payment_intent_id || invoiceRow.stripe_checkout_session_id || "—"}`,
    { size: 9, gap: 14, color: [0.5, 0.5, 0.5] },
  );
  drawLine(`Generated ${new Date().toISOString()}`, { size: 9, gap: 12, color: [0.5, 0.5, 0.5] });

  const pdfBytes = await pdf.save();
  const path = `invoice-${invoiceRow.id}.pdf`;

  // Storage write + signed URL use service_role -- no client storage policy
  // exists on this bucket, same as print-packs (see header comment).
  const serviceClient = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");
  const { error: uploadError } = await serviceClient.storage
    .from("invoices")
    .upload(path, pdfBytes, { contentType: "application/pdf", upsert: true });

  if (uploadError) {
    captureError(uploadError, { function: "generate-invoice-pdf", step: "storage upload", invoiceId });
    return new Response(JSON.stringify({ error: "Could not store the invoice PDF" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const { data: signed, error: signError } = await serviceClient.storage
    .from("invoices")
    .createSignedUrl(path, SIGNED_URL_TTL_SECONDS);

  if (signError || !signed) {
    captureError(signError ?? new Error("createSignedUrl returned no data"), {
      function: "generate-invoice-pdf",
      step: "sign url",
      invoiceId,
    });
    return new Response(JSON.stringify({ error: "Invoice PDF stored but the signed URL could not be created" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  return new Response(
    JSON.stringify({ url: signed.signedUrl, expiresInSeconds: SIGNED_URL_TTL_SECONDS }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
  );
}
