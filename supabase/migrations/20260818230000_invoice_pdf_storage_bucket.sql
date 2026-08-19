-- supabase/migrations/20260818230000_invoice_pdf_storage_bucket.sql
--
-- Hand-written per CLAUDE.md. Storage bucket for generated invoice PDFs,
-- same shape as the existing 'print-packs' bucket (Phase 4,
-- 20260808100000_phase4_tracking_and_fulfilment.sql): private (not public),
-- no storage.objects policies for authenticated/anon -- every access goes
-- through a signed, expiring URL minted by the new generate-invoice-pdf
-- Edge Function, never a public bucket URL. Unlike print-packs (staff-only,
-- called from Retool with the service_role secret), generate-invoice-pdf is
-- customer-triggered from the portal -- but the trust boundary that matters
-- here is who may READ a given invoice's row (decided by invoices_select
-- RLS, checked with the caller's own JWT inside the function), not who may
-- write to Storage directly (nobody but the function's service_role client
-- ever does that, same as print-packs).

insert into storage.buckets (id, name, public)
values ('invoices', 'invoices', false)
on conflict (id) do nothing;

-- No storage.objects policies for authenticated/anon -- intentional, see above.
