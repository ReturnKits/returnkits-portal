-- ============================================================================
-- Phase 3: invoices, gapless invoice numbering, Stripe webhook idempotency.
-- See docs/returnkits-portal-architecture.md §9.7, §20 and
-- docs/returnkits-implementation-plan.md Phase 3.
--
-- Money and webhook logic is hand-written per CLAUDE.md: "Money &
-- concurrency (webhooks, credits, references) — hand-written, never
-- generated." The Stripe webhook handler and checkout-session creator are
-- Supabase Edge Functions, deliberately outside Lovable's reach, using the
-- service_role key -- the same trust boundary as the SECURITY DEFINER
-- functions from Phase 2 (create_order/create_bundle), just implemented in
-- Deno since Stripe signature verification isn't practical in plpgsql.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Invoice numbers must be strictly sequential with no gaps (UK VAT
-- requirement, CLAUDE.md) -- a separate, dedicated sequence from
-- reference_counters, which is date-reset and allowed gaps by design (§21).
-- nextval() must only ever be called from inside the webhook handler,
-- immediately before the insert into invoices below, in the same
-- transaction -- minimising the window in which a rolled-back transaction
-- could "lose" a number.
-- ----------------------------------------------------------------------------
create sequence public.invoice_number_seq start 1;

-- ----------------------------------------------------------------------------
-- invoices — one per paid Stripe Checkout Session. Amounts are integer
-- pence, ex-VAT stored + VAT computed + total (CLAUDE.md rule 5) -- computed
-- once at webhook time from the orders' own snapshotted price_ex_vat_pence
-- and kit_types.vat_rate, never recalculated later.
-- ----------------------------------------------------------------------------
create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  invoice_number integer not null unique,
  stripe_checkout_session_id text not null unique,
  stripe_payment_intent_id text unique,
  currency text not null default 'gbp',
  subtotal_ex_vat_pence integer not null check (subtotal_ex_vat_pence >= 0),
  vat_pence integer not null check (vat_pence >= 0),
  total_inc_vat_pence integer not null check (total_inc_vat_pence >= 0),
  status text not null default 'paid' check (status in ('paid', 'voided')),
  voided_at timestamptz,
  issued_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint invoices_total_is_subtotal_plus_vat
    check (total_inc_vat_pence = subtotal_ex_vat_pence + vat_pence),
  constraint invoices_voided_has_timestamp
    check ((status = 'voided') = (voided_at is not null))
);

create index idx_invoices_company_id on public.invoices(company_id);

-- An order belongs to at most one invoice, set the moment the webhook marks
-- it paid. The CHECK ties the two facts together at the row level: you
-- cannot have an invoice_id without payment_status = 'paid'.
alter table public.orders add column invoice_id uuid references public.invoices(id);
alter table public.orders add constraint orders_invoice_implies_paid
  check (invoice_id is null or payment_status = 'paid');
create index idx_orders_invoice_id on public.orders(invoice_id);

-- ----------------------------------------------------------------------------
-- Close a real gap: orders_update_admin_or_internal (Phase 2) lets a
-- company_admin update any column on their own company's orders, including
-- payment_status -- nothing stopped a client from just PATCHing their own
-- order to "paid" without ever paying. Trigger-enforce that payment_status
-- and invoice_id can only change via service_role (the webhook handler),
-- regardless of which RLS policy would otherwise have allowed the row
-- update. is_internal()/current_role() gate *row visibility*; this gates
-- *which columns* an already-permitted update may touch.
-- ----------------------------------------------------------------------------
create or replace function public.enforce_orders_payment_fields_immutable_by_client()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (new.payment_status is distinct from old.payment_status
      or new.invoice_id is distinct from old.invoice_id)
     and auth.role() is distinct from 'service_role' then
    raise exception 'payment_status and invoice_id can only be set by the Stripe webhook handler';
  end if;
  return new;
end;
$$;

create trigger trg_orders_payment_fields_immutable
  before update on public.orders
  for each row execute function public.enforce_orders_payment_fields_immutable_by_client();

-- ----------------------------------------------------------------------------
-- stripe_webhook_events — idempotency ledger keyed on Stripe's own event id
-- (architecture §9.7: "every inbound webhook handler keys off the
-- provider's event ID and no-ops on a duplicate"). RLS enabled, zero
-- policies -- only the webhook handler (service_role, bypasses RLS) ever
-- touches this table, same pattern as reference_counters in Phase 2.
-- ----------------------------------------------------------------------------
create table public.stripe_webhook_events (
  event_id text primary key,
  event_type text not null,
  processed_at timestamptz not null default now()
);

alter table public.stripe_webhook_events enable row level security;

-- ============================================================================
-- Row Level Security
-- ============================================================================
alter table public.invoices enable row level security;

-- invoices — read-only for customers, same is_internal()/current_company()
-- shape as every tenant-scoped table since Phase 1. No INSERT/UPDATE/DELETE
-- policy for authenticated: only the webhook handler (service_role) ever
-- writes an invoice, exactly like orders/bundles route through
-- create_order()/create_bundle() rather than a direct client INSERT.
create policy "invoices_select"
  on public.invoices for select
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );
