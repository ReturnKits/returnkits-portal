-- Lets a customer paying for a kit with credit also add Enhanced Cover on
-- that same order, paid separately by card at order-creation time (added
-- 20260819, in direct response to a customer question: "why can't I add
-- cover if I pay with credits?").
--
-- Design confirmed with the user: rejected (a) making credits Enterprise-only
-- (would raise the cheapest Laptop credit price from £65 to £85 and leaves
-- Phone/Monitor credits with no cover story), and (b) bundling a fixed free
-- cover tier into every credit (removes real choice — the user explicitly
-- wants purchasable cover, not a freebie). Chosen: mixed payment per order —
-- kit paid by credit, cover paid by card, same order.
--
-- The key design decision that keeps this safe: the credit debit is
-- deferred to the same moment as cover-payment confirmation, not taken up
-- front. create_credit_order_with_paid_cover() (next migration) is the only
-- thing that ever inserts one of these orders, and it's webhook-only —
-- called from stripe-webhook after Stripe confirms the cover payment. If a
-- customer starts checkout for the cover and abandons it, nothing has
-- happened yet: no order row, no credit spent. That's the same shape every
-- other Stripe-backed flow in this app already has (order_payment,
-- credit_purchase, card_setup) — order/ledger effects only ever happen
-- inside a webhook-only RPC, never speculatively beforehand.
--
-- cover_paid_separately distinguishes this new path from the existing
-- Enterprise-bundled-cover path (which is also paid_with_credit=true with a
-- zero-charged cover_price_ex_vat_pence — see create_order's Enterprise
-- branch, which always sets the snapshot price to 0 because it's bundled
-- into the tiered credit price already). Here the cover genuinely costs
-- money and was genuinely charged, just via a second, separate Stripe line
-- item rather than folded into the kit price.

alter table public.orders
  add column cover_paid_separately boolean not null default false;

comment on column public.orders.cover_paid_separately is
  'True only for orders created by create_credit_order_with_paid_cover(): '
  'kit paid by credit, Enhanced Cover paid separately by card on the same '
  'order. Distinguishes a genuinely-charged cover from the Enterprise '
  'bundled-cover case, which also has paid_with_credit=true but always '
  'snapshots cover_price_ex_vat_pence=0.';

-- Widen the v1 restriction: a credit-paid order still can't carry a
-- separately-charged cover UNLESS it went through the new paid-cover path.
-- This keeps the constraint meaningful for every other code path (nothing
-- else may set paid_with_credit=true alongside a non-zero cover price) while
-- allowing exactly the one new, deliberately-built exception.
alter table public.orders
  drop constraint orders_credit_excludes_cover;

alter table public.orders
  add constraint orders_credit_excludes_cover
  check (
    (not paid_with_credit)
    or (cover_tier_id is null)
    or (cover_price_ex_vat_pence = 0)
    or cover_paid_separately
  );

-- cover_paid_separately should only ever be true alongside a real cover
-- tier and a real (non-zero) charge -- true with no cover, or true with a
-- zero-priced (bundled/Enterprise) cover, would be a contradiction in terms.
alter table public.orders
  add constraint orders_cover_paid_separately_implies_real_cover
  check (
    (not cover_paid_separately)
    or (cover_tier_id is not null and cover_price_ex_vat_pence > 0)
  );
