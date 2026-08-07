-- ============================================================================
-- Phase 4: ops dashboard (Retool) — tracking, fulfilment log, Print Pack.
-- See docs/returnkits-portal-architecture.md §4, §5, §7, §9.7 and
-- docs/returnkits-implementation-plan.md Phase 4.
--
-- Deliberately narrow (CLAUDE.md "do not build ahead"): this is manual
-- tracking entry by staff after buying labels in Sendcloud's dashboard by
-- hand. The ShippingProvider interface, Sendcloud API integration, and
-- carrier tracking webhooks are Phase 6 — not built here. Column names
-- match architecture §4 exactly so that later automation is a data-write
-- change, not a schema change.
-- ============================================================================

alter table public.orders
  add column outbound_courier text,
  add column outbound_tracking_number text,
  add column outbound_tracking_url text,
  add column return_courier text,
  add column return_tracking_number text,
  add column return_tracking_url text,
  -- Append-only accountability trail (architecture §5: "records who
  -- confirmed and when... not just tracking"). Every state-changing RPC
  -- below appends one entry: {action, actor_id, at, detail}. Never
  -- rewritten, only appended to -- mirrors audit_log's append-only design
  -- but scoped to the order itself for a customer-facing timeline (Phase 4
  -- Lovable status view reads this directly).
  add column fulfilment_log jsonb not null default '[]'::jsonb,
  add column confirmed_sent_at timestamptz,
  add column confirmed_sent_by uuid references public.users(id),
  add column confirmed_received_at timestamptz,
  add column confirmed_received_by uuid references public.users(id),
  -- Storage object path, not a URL -- signed URLs expire (architecture
  -- §9.7: "signed, expiring URLs for all documents"), so nothing durable
  -- can store one. A fresh signed URL is minted on each request from this
  -- path. Nullable: most orders never need a regenerated pack.
  add column print_pack_storage_path text,
  add column print_pack_generated_at timestamptz;

-- Matches architecture §4's indexing note: tracking numbers are looked up
-- by inbound webhook matching later (Phase 6) and by staff search now.
create index idx_orders_outbound_tracking_number on public.orders(outbound_tracking_number)
  where outbound_tracking_number is not null;
create index idx_orders_return_tracking_number on public.orders(return_tracking_number)
  where return_tracking_number is not null;

-- ----------------------------------------------------------------------------
-- Storage bucket for Print Packs. Private (not public) -- every access goes
-- through a signed, expiring URL minted by the generate-print-pack Edge
-- Function (Phase 4, hand-written), never a public bucket URL.
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('print-packs', 'print-packs', false)
on conflict (id) do nothing;

-- No storage.objects policies for authenticated/anon -- only service_role
-- (the Edge Function) ever reads/writes this bucket, same trust boundary as
-- stripe_webhook_events/reference_counters: RLS-equivalent protection by
-- having no policy at all for client-facing roles, rather than trying to
-- scope object-level access by company through storage policies.
