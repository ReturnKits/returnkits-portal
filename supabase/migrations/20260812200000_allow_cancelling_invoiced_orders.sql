-- Fix for a real failure hit by cancel_order (20260812): orders_invoice_implies_paid
-- was written before cancellation existed as a state, and only permitted
-- payment_status = 'paid' whenever invoice_id was set. That's correct for
-- every other transition (an invoiced order should never silently become
-- 'pending' again), but wrong for cancellation: RKP-260812-001 was paid via
-- live Stripe, then refunded directly in the Stripe dashboard (outside the
-- app -- no in-app refund flow exists, per CLAUDE.md "no refunds"). The
-- invoice remains historically accurate (a real charge happened) and is
-- deliberately NOT voided here -- voiding is for invoices issued in error,
-- not for legitimate payments refunded afterwards. cancel_order() leaves
-- invoice_id untouched; this constraint just needs to allow the order's
-- own payment_status to move to 'cancelled' while that invoice stays on
-- the record.
alter table public.orders drop constraint orders_invoice_implies_paid;

alter table public.orders add constraint orders_invoice_implies_paid
  check (invoice_id is null or payment_status in ('paid', 'cancelled'));
