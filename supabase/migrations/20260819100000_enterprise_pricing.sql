-- supabase/migrations/20260819100000_enterprise_pricing.sql
--
-- Hand-written per CLAUDE.md ("Money & concurrency ... hand-written, never
-- generated"). Adds a self-serve "Enterprise pricing" switch for Laptop
-- credits: once a company turns it on, buying Laptop credits uses
-- per-purchase volume tiers instead of the flat kit_types.price_ex_vat_pence,
-- and every tier bundles Enhanced Cover (up to £2,000) into the credit price
-- at no separate charge when that credit is later redeemed for an order.
--
-- Scope, confirmed with the user 20260819:
--   - Laptop only (not Phone/Monitor).
--   - Tier is decided PER PURCHASE by the quantity in that one transaction,
--     not by cumulative lifetime volume -- e.g. buying 12 credits in one
--     checkout prices all 12 at the 10+ rate. This avoids needing a running-
--     total lookup and the associated race-condition surface this project's
--     own audit already flagged once for the free-kit-claim bug class.
--   - Toggled by the company's own admin, self-serve, from Settings -- not
--     staff-only. No new RLS policy is needed for this: companies_update_admin
--     (Phase "Settings page" feature, see CLAUDE.md) already lets a
--     company_admin write any column on their own company row.
--   - The 1-9 tier (£85) is priced ABOVE the flat self-serve Laptop price
--     (£65) -- confirmed intentional. Every tier price is exactly
--     "£65 kit + Enhanced Cover-2000, with the cover portion volume-
--     discounted": £85-£65=£20 (Cover-2000's own standalone price), £80-£65=
--     £15, £77-£65=£12, £74-£65=£9. Enterprise pricing is really "Enhanced
--     Cover volume pricing for Laptop credits", not a kit-price discount --
--     so there's no incentive for a company to self-serve-toggle this on
--     just to buy laptops cheaper; the price only goes below flat-price
--     territory in the sense that per-unit cover is discounted at volume.
--
-- Known v1 simplification, not solved here (documented rather than
-- engineered around, same pattern as the "v1 restriction" already accepted
-- for credit-paid orders excluding Enhanced Cover): credit_ledger balance is
-- a fungible SUM per (company, kit_type), per the existing "Credits typed
-- per kit type" locked decision -- there is no per-purchase-batch tracking
-- of which specific credits were bought under Enterprise pricing. This means
-- whether a redeemed Laptop credit gets bundled cover attached is decided by
-- the company's CURRENT enterprise_pricing_enabled flag at REDEMPTION time,
-- not by what was true when that specific credit was purchased. A company
-- could buy credits at flat price, later toggle Enterprise on, and redeem
-- those same credits with cover now attached for free. This is a narrow,
-- low-value edge case (bounded by however many credits sit unredeemed at the
-- moment of toggling) and is accepted rather than solved with per-batch
-- tracking, which would be a much bigger schema change for a small risk.

-- ---------------------------------------------------------------------
-- The switch itself.
-- ---------------------------------------------------------------------
alter table public.companies
  add column enterprise_pricing_enabled boolean not null default false;

comment on column public.companies.enterprise_pricing_enabled is
  'Self-serve switch (company_admin, Settings page). When true, Laptop credit purchases use enterprise_pricing_tiers instead of the flat kit_types price, and every redeemed Laptop credit auto-attaches Enhanced Cover (up to £2,000) at no extra charge.';

-- ---------------------------------------------------------------------
-- Tier table -- same "world-readable, no write policy, managed by
-- migration only" shape as kit_types/cover_tiers.
-- ---------------------------------------------------------------------
create table public.enterprise_pricing_tiers (
  id uuid primary key default gen_random_uuid(),
  kit_type_id text not null references public.kit_types(id),
  min_quantity integer not null check (min_quantity >= 1),
  price_ex_vat_pence integer not null check (price_ex_vat_pence >= 0),
  includes_cover_tier_id text references public.cover_tiers(id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (kit_type_id, min_quantity)
);

comment on table public.enterprise_pricing_tiers is
  'Per-purchase volume price breaks for Enterprise-pricing companies, by kit type. The price applies to every unit in a purchase once its quantity meets min_quantity (the highest qualifying tier wins). includes_cover_tier_id, when set, is the Enhanced Cover tier automatically (and freely) attached to any order later placed using a credit bought at this tier -- see create_order/create_internal_order.';

alter table public.enterprise_pricing_tiers enable row level security;

create policy enterprise_pricing_tiers_select on public.enterprise_pricing_tiers
  for select
  to authenticated
  using (true);

-- No insert/update/delete policy -- managed by migration only, same as
-- kit_types and cover_tiers.

insert into public.enterprise_pricing_tiers (kit_type_id, min_quantity, price_ex_vat_pence, includes_cover_tier_id)
values
  ('laptop', 1, 8500, 'up_to_2000'),
  ('laptop', 10, 8000, 'up_to_2000'),
  ('laptop', 25, 7700, 'up_to_2000'),
  ('laptop', 50, 7400, 'up_to_2000');

-- ---------------------------------------------------------------------
-- Relax the credit/cover exclusion so a credit-paid order CAN carry
-- Enhanced Cover, but only when that cover is bundled/free (never a
-- separate card charge stacked on top of a credit redemption -- the
-- "partly paid by credit, partly owed by card" complexity the original
-- v1 restriction was written to avoid stays avoided).
-- ---------------------------------------------------------------------
alter table public.orders drop constraint orders_credit_excludes_cover;

alter table public.orders add constraint orders_credit_excludes_cover
  check (not paid_with_credit or cover_tier_id is null or cover_price_ex_vat_pence = 0);
