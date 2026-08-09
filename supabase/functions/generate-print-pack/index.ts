// supabase/functions/generate-print-pack/index.ts
//
// Hand-written per CLAUDE.md. Called from Retool (the shared service_role
// credential, per the Phase 4 auth model already used by
// mark_order_dispatched/create_internal_order) to render and store the
// Print Pack for an order, then hand back a signed, expiring URL.
//
// Renders with pdf-lib rather than React-PDF/Puppeteer: architecture §5
// suggests those, but neither runs in the Deno Edge Function sandbox
// (Puppeteer needs a real Chromium binary; React-PDF's renderer pulls in
// Node-only internals). pdf-lib is pure JS with no native dependencies and
// is a known-working choice in Deno/edge runtimes -- a deliberate, narrower
// substitution for this phase, not a shortcut that loses functionality: the
// Print Pack is a simple one-page document, not a complex layout.
//
// Storage: the private 'print-packs' bucket (created in
// 20260808100000_phase4_tracking_and_fulfilment.sql). No client role has
// any storage policy on it -- only this function (via service_role) ever
// reads/writes it, same trust boundary as reference_counters/
// stripe_webhook_events. Every access outside this function goes through a
// freshly-minted signed URL (architecture §9.7): the object path itself is
// stored on the order (print_pack_storage_path), never a URL, since signed
// URLs expire.

import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";
import { createClient } from "jsr:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!supabaseUrl || !serviceRoleKey) {
  console.error("generate-print-pack: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
}

const supabase = createClient(supabaseUrl ?? "", serviceRoleKey ?? "");

const SIGNED_URL_TTL_SECONDS = 60 * 60; // 1 hour -- long enough for staff to open and print, short enough not to linger.

function formatAddress(parts: Array<string | null | undefined>): string[] {
  return parts.filter((part): part is string => Boolean(part && part.trim()));
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
  }

  // Same auth model as mark_order_dispatched/create_internal_order: only
  // the holder of the service_role secret (Retool's shared connection) may
  // call this. Deployed with verify_jwt: false so we can do this exact
  // check ourselves rather than accepting any signed-in user's JWT.
  const authHeader = req.headers.get("Authorization") ?? "";
  if (authHeader !== `Bearer ${serviceRoleKey}`) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  let body: { orderId?: unknown; actorId?: unknown };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), { status: 400 });
  }

  const orderId = typeof body.orderId === "string" ? body.orderId : null;
  const actorId = typeof body.actorId === "string" ? body.actorId : null;
  if (!orderId || !actorId) {
    return new Response(JSON.stringify({ error: "orderId and actorId are required" }), { status: 400 });
  }

  const { data: actor, error: actorError } = await supabase
    .from("users")
    .select("id, role")
    .eq("id", actorId)
    .maybeSingle();
  if (actorError || !actor || !["internal_admin", "internal_ops"].includes(actor.role)) {
    return new Response(JSON.stringify({ error: "actorId is not an internal staff member" }), { status: 403 });
  }

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select(
      `id, reference, service_type, device_reference, requested_send_date,
       company:companies(name),
       kit_types(label),
       employees(full_name, address_line1, address_line2, city, postcode, country),
       return_address:addresses!orders_return_address_id_fkey(label, address_line1, address_line2, city, postcode, country)`,
    )
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) {
    return new Response(JSON.stringify({ error: "Order not found" }), { status: 404 });
  }

  // supabase-js types these embedded relations loosely; narrow what we need.
  const o = order as unknown as {
    id: string;
    reference: string;
    service_type: string;
    device_reference: string | null;
    company: { name: string } | null;
    kit_types: { label: string } | null;
    employees: {
      full_name: string;
      address_line1: string | null;
      address_line2: string | null;
      city: string | null;
      postcode: string | null;
      country: string | null;
    } | null;
    return_address: {
      label: string;
      address_line1: string;
      address_line2: string | null;
      city: string;
      postcode: string;
      country: string;
    } | null;
  };

  // ---- Render the PDF ----
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([595.28, 841.89]); // A4 in points
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);

  let y = 780;
  const left = 56;

  const drawLine = (text: string, opts: { size?: number; useBold?: boolean; gap?: number; color?: [number, number, number] } = {}) => {
    const { size = 11, useBold = false, gap = 18, color = [0, 0, 0] } = opts;
    page.drawText(text, {
      x: left,
      y,
      size,
      font: useBold ? bold : font,
      color: rgb(color[0], color[1], color[2]),
    });
    y -= gap;
  };

  drawLine("ReturnKits", { size: 22, useBold: true, gap: 30 });
  drawLine("Print Pack", { size: 14, useBold: true, gap: 26, color: [0.35, 0.35, 0.35] });

  drawLine(`Order reference: ${o.reference}`, { useBold: true });
  drawLine(`Company: ${o.company?.name ?? "—"}`);
  drawLine(`Kit: ${o.kit_types?.label ?? "—"}`);
  drawLine(`Service: ${o.service_type === "return" ? "Return (to company address)" : "Ship to new employee"}`);
  if (o.device_reference) drawLine(`Device reference: ${o.device_reference}`);
  y -= 10;

  if (o.service_type === "return") {
    drawLine("Return by post to:", { useBold: true, gap: 20 });
    const addressLines = o.return_address
      ? formatAddress([
          o.return_address.label,
          o.return_address.address_line1,
          o.return_address.address_line2,
          o.return_address.city,
          o.return_address.postcode,
          o.return_address.country,
        ])
      : ["No return address on file — contact ReturnKits before posting."];
    for (const line of addressLines) drawLine(line, { gap: 16 });
    y -= 10;
    drawLine("Pack the device securely using the enclosed materials and attach the", { size: 10, gap: 14, color: [0.3, 0.3, 0.3] });
    drawLine("prepaid return label before dropping off with the carrier.", { size: 10, gap: 14, color: [0.3, 0.3, 0.3] });
  } else {
    drawLine("Ship to:", { useBold: true, gap: 20 });
    const addressLines = o.employees
      ? formatAddress([
          o.employees.full_name,
          o.employees.address_line1,
          o.employees.address_line2,
          o.employees.city,
          o.employees.postcode,
          o.employees.country,
        ])
      : ["No recipient address on file."];
    for (const line of addressLines) drawLine(line, { gap: 16 });
  }

  y -= 20;
  drawLine(`Generated ${new Date().toISOString()}`, { size: 9, gap: 12, color: [0.5, 0.5, 0.5] });

  const pdfBytes = await pdf.save();

  const path = `print-pack-${o.id}.pdf`;

  const { error: uploadError } = await supabase.storage
    .from("print-packs")
    .upload(path, pdfBytes, { contentType: "application/pdf", upsert: true });

  if (uploadError) {
    console.error("generate-print-pack: upload failed", uploadError);
    return new Response(JSON.stringify({ error: "Could not store the Print Pack" }), { status: 500 });
  }

  const generatedAt = new Date().toISOString();
  await supabase
    .from("orders")
    .update({ print_pack_storage_path: path, print_pack_generated_at: generatedAt })
    .eq("id", orderId);

  await supabase.rpc("log_audit", {
    p_actor_id: actorId,
    p_action: "order.print_pack_generated",
    p_target_table: "orders",
    p_target_id: orderId,
    p_before: null,
    p_after: { print_pack_storage_path: path },
  });

  const { data: signed, error: signError } = await supabase.storage
    .from("print-packs")
    .createSignedUrl(path, SIGNED_URL_TTL_SECONDS);

  if (signError || !signed) {
    console.error("generate-print-pack: signing failed", signError);
    return new Response(JSON.stringify({ error: "Print Pack stored but the signed URL could not be created" }), {
      status: 500,
    });
  }

  return new Response(JSON.stringify({ url: signed.signedUrl, storagePath: path, expiresInSeconds: SIGNED_URL_TTL_SECONDS }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
