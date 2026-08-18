-- supabase/migrations/20260818220000_not_vat_registered_set_vat_rate_zero.sql
--
-- Hand-written per CLAUDE.md. ReturnKits Ltd is not currently VAT-registered
-- (confirmed with the user 20260818) -- a business that isn't VAT-registered
-- must not charge VAT, so kit_types.vat_rate and cover_tiers.vat_rate both
-- move from their seeded 0.20 default to 0.00. This is exactly the "an
-- accountant's ruling changes data, not code" pattern these columns were
-- built for (see the Enhanced Cover locked decision in CLAUDE.md) -- no
-- application code changes anywhere, since create-checkout-session,
-- create-credit-checkout-session, record_stripe_payment and
-- record_credit_purchase all already read vat_rate off these two tables
-- per line rather than hardcoding 20% anywhere.
--
-- Pricing decision confirmed with the user: keep the listed ex-VAT prices
-- exactly as they are (Laptop £65 / Phone £40 / Monitor £85 ex VAT, Cover
-- £5/£10/£20 ex VAT) rather than grossing them up to match previous inc-VAT
-- totals -- customers now pay less overall (e.g. the laptop kit drops from
-- £78 total to £65 total), and per-order revenue drops by the same amount.
-- That was an explicit, informed choice, not an oversight.
--
-- Column defaults are also updated to 0.00 so any future kit_types/
-- cover_tiers row added by a later migration doesn't silently reintroduce
-- 20% VAT -- both tables are seed-only (no write policy for authenticated,
-- "managed by migration only" per their locked decisions), so this default
-- only ever matters to whoever writes the next migration, but it should
-- still be correct.
--
-- Not touching: kit_types.price_ex_vat_pence / cover_tiers.price_ex_vat_pence
-- (unchanged, per the pricing decision above), the customer-facing
-- companies.vat_number field (that's the CUSTOMER's own VAT number,
-- unrelated to whether ReturnKits itself charges VAT), and invoices.* /
-- orders.* -- those are historical snapshots at time of purchase and must
-- stay exactly as they were charged; this migration only changes the rate
-- applied to orders placed from now on.

alter table public.kit_types alter column vat_rate set default 0.00;
alter table public.cover_tiers alter column vat_rate set default 0.00;

update public.kit_types set vat_rate = 0.00 where vat_rate <> 0.00;
update public.cover_tiers set vat_rate = 0.00 where vat_rate <> 0.00;
