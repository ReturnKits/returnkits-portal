-- Backfilled from the hosted project (applied there directly via apply_migration)
-- so a local `db reset` reproduces hosted.

-- Adds a staff-only kit-type visibility flag, and activates two catch-all
-- kit types (Accessories, Miscellaneous) scoped to internal/Retool order
-- creation only — never shown in the self-serve customer portal.
-- See CLAUDE.md for full reasoning. Widens the two enumerated CHECK
-- constraints (kit_types_id_check, kit_types_reference_prefix_check) to
-- admit the new 'miscellaneous' id / 'RKX' prefix — both were hard-coded
-- to the original five kit types.

alter table public.kit_types
  add column internal_only boolean not null default false;

alter table public.kit_types drop constraint kit_types_id_check;
alter table public.kit_types add constraint kit_types_id_check
  check (id = any (array['laptop','phone','monitor','tablet','accessories','miscellaneous']));

alter table public.kit_types drop constraint kit_types_reference_prefix_check;
alter table public.kit_types add constraint kit_types_reference_prefix_check
  check (reference_prefix ~ '^RK[LTPMAX]$');

-- Accessories already existed (inactive, no price) — activate it as a
-- staff-only, non-billable catch-all per explicit instruction: "leave the
-- charge out, this shouldn't be an option for customers, only for my
-- custom orders."
update public.kit_types
set active = true, internal_only = true, price_ex_vat_pence = 0
where id = 'accessories';

-- New Miscellaneous kit type, same treatment (no price preference given —
-- matched to Accessories' non-billable pattern). RKX reference prefix —
-- A/L/M/P/T already taken by the other five kit types.
insert into public.kit_types (id, label, price_ex_vat_pence, vat_rate, active, internal_only, reference_prefix)
values ('miscellaneous', 'Miscellaneous Kit', 0, 0.000, true, true, 'RKX');
