-- ============================================================================
-- Phase 2: kit_types, reference_counters, orders, bundles, addresses,
-- employees. See docs/returnkits-portal-architecture.md §4, §20, §21 and
-- docs/returnkits-implementation-plan.md Phase 2.
--
-- Reference generation and order creation are hand-written SECURITY DEFINER
-- functions (CLAUDE.md: "money & concurrency (webhooks, credits,
-- references) — hand-written, never generated"). Clients never insert an
-- order row directly or choose their own reference — see the no-INSERT-
-- policy pattern already established for users/invites in Phase 1.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- kit_types — a table, not a TypeScript union, so switching Tablet/
-- Accessories back on is a data change (architecture §20). Tablet and
-- Accessories are seeded inactive with no price yet ("TBC" in the doc).
-- ----------------------------------------------------------------------------
create table public.kit_types (
  id text primary key check (id in ('laptop', 'phone', 'monitor', 'tablet', 'accessories')),
  label text not null,
  -- Order-reference prefix (architecture §21). RKL/RKT/RKP/RKM/RKA.
  reference_prefix text not null unique check (reference_prefix ~ '^RK[LTPMA]$'),
  -- Ex-VAT price is the single source of truth (CLAUDE.md rule 5) — integer
  -- pence, never a float. Inc-VAT is computed at display/invoice time, never
  -- stored. Nullable so a kit type can exist (and be referenced) before its
  -- price is confirmed, as long as it stays inactive — enforced below.
  price_ex_vat_pence integer check (price_ex_vat_pence >= 0),
  vat_rate numeric(4, 3) not null default 0.20,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint kit_types_active_needs_price check (not active or price_ex_vat_pence is not null)
);

insert into public.kit_types (id, label, reference_prefix, price_ex_vat_pence, active) values
  ('laptop', 'Laptop Kit', 'RKL', 6500, true),
  ('phone', 'Phone Kit', 'RKP', 4000, true),
  ('monitor', 'Monitor Kit', 'RKM', 8500, true),
  ('tablet', 'Tablet Kit', 'RKT', null, false),
  ('accessories', 'Accessories Kit', 'RKA', null, false);

create trigger trg_kit_types_updated_at
  before update on public.kit_types
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- reference_counters — atomic, daily-resetting, per-prefix. Never touched
-- directly by any client; the sole write path is next_reference_number()
-- below. RLS is enabled with zero policies, so even a compromised client
-- role reads/writes nothing here — only the SECURITY DEFINER functions
-- (owned by postgres, which bypasses RLS) can touch it.
-- ----------------------------------------------------------------------------
create table public.reference_counters (
  prefix text not null,
  ref_date date not null,
  last_value integer not null default 0,
  primary key (prefix, ref_date)
);

alter table public.reference_counters enable row level security;

-- ----------------------------------------------------------------------------
-- next_reference_number — the atomic generator (architecture §21, point 1).
-- INSERT ... ON CONFLICT DO UPDATE ... RETURNING is a single statement, so
-- two concurrent callers for the same prefix/date can't both read the same
-- last_value and both write the next one — Postgres serializes the
-- conflicting writes and each caller gets a distinct value.
--
-- Date is pinned to Europe/London (§21 point 2), never UTC — a 00:30 BST
-- order is 23:30 UTC the day before, which would otherwise mint yesterday's
-- date and risk colliding with an already-issued reference.
--
-- Sequence is zero-padded to 3 digits and never wraps (§21 point 3):
-- lpad('1000', 3, '0') is a no-op once the value is already wider than 3
-- digits, so RKL-260807-1000 and beyond fall out naturally with no special
-- casing. Never parse this format by fixed width — split on '-'.
-- ----------------------------------------------------------------------------
create or replace function public.next_reference_number(p_prefix text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref_date date := (now() at time zone 'Europe/London')::date;
  v_seq integer;
begin
  insert into public.reference_counters (prefix, ref_date, last_value)
  values (p_prefix, v_ref_date, 1)
  on conflict (prefix, ref_date)
  do update set last_value = public.reference_counters.last_value + 1
  returning last_value into v_seq;

  return p_prefix || '-' || to_char(v_ref_date, 'YYMMDD') || '-' || lpad(v_seq::text, 3, '0');
end;
$$;

-- Internal plumbing only — called from create_order()/create_bundle() below,
-- never directly by a client (mirrors log_audit() in Phase 1).
revoke all on function public.next_reference_number(text) from public;

-- ----------------------------------------------------------------------------
-- bundles — groups orders placed together (architecture §4/§5). Reference
-- format BND-YYMMDD-NNN, same atomic generator, separate counter (its own
-- 'BND' prefix keeps the sequence independent of any kit-type prefix).
-- ----------------------------------------------------------------------------
create table public.bundles (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  reference text not null unique,
  created_by uuid not null references public.users(id),
  created_at timestamptz not null default now()
);

create index idx_bundles_company_id on public.bundles(company_id);

-- ----------------------------------------------------------------------------
-- addresses — fixed company locations (warehouse, IT office). Used as the
-- destination for returned devices.
-- ----------------------------------------------------------------------------
create table public.addresses (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  label text not null,
  address_line1 text not null,
  address_line2 text,
  city text not null,
  postcode text not null,
  country text not null default 'GB',
  is_default_return boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_addresses_company_id on public.addresses(company_id);

create trigger trg_addresses_updated_at
  before update on public.addresses
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- employees — recipient people (the leaver returning a kit, or the new
-- joiner receiving one), distinct from the fixed addresses above
-- (architecture §4/§13).
-- ----------------------------------------------------------------------------
create table public.employees (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  full_name text not null,
  email text,
  phone text,
  address_line1 text,
  address_line2 text,
  city text,
  postcode text,
  country text default 'GB',
  last_kit_ordered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_employees_company_id on public.employees(company_id);

create trigger trg_employees_updated_at
  before update on public.employees
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- orders — flat model: one row per kit, tracking columns live on the row,
-- bundle_id groups multi-item orders (locked decision, CLAUDE.md). Payment
-- and shipping-tracking columns are deliberately NOT added yet — Phase 3
-- (payments) and Phase 4/§7 (ops/tracking) own those and land in their own
-- migrations, per "do not build ahead."
--
-- `reference` (RKL-260807-001, ours, immutable) is distinct from
-- `order_reference` (the customer's own PO/ticket ref, theirs, free text) —
-- architecture §4 names both fields explicitly, this keeps that naming.
-- ----------------------------------------------------------------------------
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  bundle_id uuid references public.bundles(id) on delete set null,
  reference text not null unique,
  order_reference text,
  kit_type_id text not null references public.kit_types(id),
  service_type text not null check (service_type in ('return', 'ship_to_new_employee')),
  source text not null default 'customer' check (source in ('customer', 'internal_staff', 'bamboohr_auto')),
  created_by uuid not null references public.users(id),
  employee_id uuid not null references public.employees(id),
  return_address_id uuid references public.addresses(id),
  device_reference text,
  -- Snapshotted at order creation, integer pence, ex-VAT only (CLAUDE.md
  -- rule 5) — kit_types.price_ex_vat_pence can change later without
  -- rewriting historical orders.
  price_ex_vat_pence integer not null check (price_ex_vat_pence >= 0),
  payment_status text not null default 'pending' check (payment_status in ('pending', 'paid', 'cancelled')),
  fulfilment_status text not null default 'awaiting_dispatch' check (
    fulfilment_status in (
      'awaiting_dispatch', 'dispatched', 'confirmed_sent', 'delivered', 'confirmed_received', 'completed', 'cancelled'
    )
  ),
  requested_send_date date,
  leaver_last_day date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- A return needs somewhere to return the device to; a ship-to-new-employee
  -- order doesn't (it ships to the employee, not a company address). Catches
  -- the Base44-style "enum declared but not enforced" gotcha at the DB layer.
  constraint orders_return_needs_address check (service_type <> 'return' or return_address_id is not null)
);

create index idx_orders_company_id on public.orders(company_id);
create index idx_orders_bundle_id on public.orders(bundle_id);
create index idx_orders_fulfilment_status on public.orders(fulfilment_status);
create index idx_orders_employee_id on public.orders(employee_id);

create trigger trg_orders_updated_at
  before update on public.orders
  for each row execute function public.set_updated_at();

-- References are immutable once issued (architecture §21, point 4) — even
-- if an order's kit type later changes, the reference does not regenerate.
-- Enforced here rather than relying on RLS alone, so it holds regardless of
-- which policy or role performs the UPDATE.
create or replace function public.enforce_order_reference_immutable()
returns trigger
language plpgsql
as $$
begin
  if new.reference is distinct from old.reference then
    raise exception 'order reference is immutable once issued (was %, attempted %)', old.reference, new.reference;
  end if;
  return new;
end;
$$;

create trigger trg_orders_reference_immutable
  before update on public.orders
  for each row execute function public.enforce_order_reference_immutable();

-- ----------------------------------------------------------------------------
-- create_bundle / create_order — the only sanctioned write paths. Both
-- SECURITY DEFINER, both single-transaction, both call the atomic reference
-- generator above. No INSERT policy exists on bundles or orders for
-- `authenticated` for exactly the reason there's none on users/invites in
-- Phase 1: a raw client-side INSERT could choose its own reference or skip
-- the counter entirely.
-- ----------------------------------------------------------------------------
create or replace function public.create_bundle()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid := public.current_company();
  v_bundle_id uuid;
  v_ref text;
begin
  if v_company is null then
    raise exception 'Must belong to a company';
  end if;

  v_ref := public.next_reference_number('BND');

  insert into public.bundles (company_id, reference, created_by)
  values (v_company, v_ref, auth.uid())
  returning id into v_bundle_id;

  perform public.log_audit(auth.uid(), 'bundle.create', 'bundles', v_bundle_id, null,
    jsonb_build_object('reference', v_ref));

  return v_bundle_id;
end;
$$;

revoke all on function public.create_bundle() from public;
grant execute on function public.create_bundle() to authenticated;

create or replace function public.create_order(
  p_kit_type_id text,
  p_service_type text,
  p_employee_id uuid,
  p_return_address_id uuid default null,
  p_device_reference text default null,
  p_requested_send_date date default null,
  p_leaver_last_day date default null,
  p_bundle_id uuid default null,
  p_order_reference text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid := public.current_company();
  v_prefix text;
  v_price integer;
  v_active boolean;
  v_ref text;
  v_order_id uuid;
begin
  if v_company is null then
    raise exception 'Must belong to a company';
  end if;

  if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
    raise exception 'Employee not found for this company';
  end if;

  if p_return_address_id is not null
     and not exists (select 1 from public.addresses where id = p_return_address_id and company_id = v_company) then
    raise exception 'Return address not found for this company';
  end if;

  if p_bundle_id is not null
     and not exists (select 1 from public.bundles where id = p_bundle_id and company_id = v_company) then
    raise exception 'Bundle not found for this company';
  end if;

  select reference_prefix, price_ex_vat_pence, active
  into v_prefix, v_price, v_active
  from public.kit_types
  where id = p_kit_type_id;

  if v_prefix is null then
    raise exception 'Unknown kit type: %', p_kit_type_id;
  end if;

  if not v_active then
    raise exception 'Kit type % is not currently orderable', p_kit_type_id;
  end if;

  v_ref := public.next_reference_number(v_prefix);

  insert into public.orders (
    company_id, bundle_id, reference, order_reference, kit_type_id, service_type,
    source, created_by, employee_id, return_address_id, device_reference,
    price_ex_vat_pence, requested_send_date, leaver_last_day
  )
  values (
    v_company, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'customer', auth.uid(), p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day
  )
  returning id into v_order_id;

  perform public.log_audit(auth.uid(), 'order.create', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type));

  return v_order_id;
end;
$$;

revoke all on function public.create_order(text, text, uuid, uuid, text, date, date, uuid, text) from public;
grant execute on function public.create_order(text, text, uuid, uuid, text, date, date, uuid, text) to authenticated;

-- ============================================================================
-- Row Level Security
-- ============================================================================
alter table public.kit_types enable row level security;
alter table public.bundles enable row level security;
alter table public.addresses enable row level security;
alter table public.employees enable row level security;
alter table public.orders enable row level security;

-- kit_types — public catalogue data, no tenant scoping. Inactive rows stay
-- visible (Lovable filters `active = true` for the customer-facing
-- catalogue); internal ops needs to see the full set including inactive.
create policy "kit_types_select_all"
  on public.kit_types for select
  to authenticated
  using (true);

-- bundles — same is_internal()/current_company() shape as every
-- tenant-scoped table since Phase 1. No INSERT policy: create_bundle() only.
create policy "bundles_select"
  on public.bundles for select
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );

-- addresses — company_admin/company_member manage their own company's
-- addresses directly (no money or concurrency concern here, unlike orders).
create policy "addresses_select"
  on public.addresses for select
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );

create policy "addresses_insert"
  on public.addresses for insert
  to authenticated
  with check (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );

create policy "addresses_update"
  on public.addresses for update
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  )
  with check (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );

create policy "addresses_delete"
  on public.addresses for delete
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );

-- employees — same shape as addresses: directory maintenance, no
-- concurrency/money concern, so no SECURITY DEFINER wrapper needed.
create policy "employees_select"
  on public.employees for select
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );

create policy "employees_insert"
  on public.employees for insert
  to authenticated
  with check (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );

create policy "employees_update"
  on public.employees for update
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  )
  with check (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );

create policy "employees_delete"
  on public.employees for delete
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );

-- orders — the collaboration direction matters here exactly as much as it
-- did for users in Phase 1: any member of the company must see a colleague's
-- order, not just their own. No INSERT policy: create_order() only. UPDATE
-- is restricted to company_admin/internal for now — cancellation and other
-- state transitions are undesigned until credits/refund rules land
-- (deferred per CLAUDE.md), so this stays conservative rather than open.
create policy "orders_select"
  on public.orders for select
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );

create policy "orders_update_admin_or_internal"
  on public.orders for update
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_role() = 'company_admin')
  )
  with check (
    public.is_internal()
    or (company_id = public.current_company() and public.current_role() = 'company_admin')
  );
