-- ============================================================================
-- Phase 5: Notifications schema. communication_log (architecture §13, §5) is
-- explicitly customer-visible -- not just an internal debug table -- so
-- customers get a "here's everything we've sent you" view. That's why RLS
-- grants authenticated SELECT scoped to their own company, same pattern as
-- every other tenant-scoped table (CLAUDE.md rule #6: new tenant-scoped
-- table -> RLS policy in the same commit).
--
-- notification_preferences lets staff mute noisy event types without a code
-- change (architecture §5: "internal admins mute noisy events... without
-- touching code"). Company admins can also see/toggle their own company's
-- preferences -- there's no reason a company shouldn't be able to opt out of
-- non-essential nudges themselves.
--
-- Both tables are written to ONLY by the send-email Edge Function
-- (service_role) -- inserts/updates never happen from the client, same trust
-- boundary as reference_counters and stripe_webhook_events. Company admins
-- get read access to communication_log and read/write to their own
-- notification_preferences rows, nothing else.
-- ============================================================================

create table public.communication_log (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  channel text not null default 'email' check (channel in ('email', 'sms')),
  type text not null check (type in (
    'order_confirmation', 'dispatched', 'checkin_sent', 'checkin_received'
  )),
  audience text not null check (audience in ('customer', 'internal')),
  recipient text not null,
  subject text not null,
  status text not null default 'queued' check (status in (
    'queued', 'sent', 'delivered', 'bounced', 'complained', 'failed'
  )),
  provider_message_id text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_communication_log_company_id on public.communication_log(company_id);
create index idx_communication_log_order_id on public.communication_log(order_id) where order_id is not null;
create unique index idx_communication_log_provider_message_id on public.communication_log(provider_message_id) where provider_message_id is not null;

alter table public.communication_log enable row level security;

create policy communication_log_select_own_company
  on public.communication_log for select
  to authenticated
  using (company_id = public.current_company());

-- No insert/update/delete policy for authenticated or anon: every row is
-- written by the send-email Edge Function and updated by the Resend webhook
-- handler, both service_role. Customers can only ever read.

create table public.notification_preferences (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  event_type text not null check (event_type in (
    'order_confirmation', 'dispatched', 'checkin_sent', 'checkin_received'
  )),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, event_type)
);

alter table public.notification_preferences enable row level security;

create policy notification_preferences_select_own_company
  on public.notification_preferences for select
  to authenticated
  using (company_id = public.current_company());

create policy notification_preferences_update_own_company
  on public.notification_preferences for update
  to authenticated
  using (company_id = public.current_company())
  with check (company_id = public.current_company());

-- No insert/delete for authenticated -- rows are seeded per-company (see
-- seed_default_notification_preferences below) rather than created ad hoc,
-- so a company can only ever toggle enabled on an existing row, never
-- fabricate a new event_type or delete their record of one.

create or replace function public.seed_default_notification_preferences()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notification_preferences (company_id, event_type, enabled)
  select new.id, event_type, true
  from unnest(array['order_confirmation', 'dispatched', 'checkin_sent', 'checkin_received']) as event_type
  on conflict (company_id, event_type) do nothing;
  return new;
end;
$$;

create trigger trg_seed_notification_preferences
  after insert on public.companies
  for each row execute function public.seed_default_notification_preferences();

revoke all on function public.seed_default_notification_preferences() from public;
revoke execute on function public.seed_default_notification_preferences() from anon, authenticated;

-- Helper the send-email function calls before every send (architecture §5:
-- "notification_preferences is checked by the worker before every send").
-- Defaults to true if no row exists yet (e.g. companies created before this
-- migration) rather than silently dropping sends for pre-existing tenants.
create or replace function public.notification_enabled(p_company_id uuid, p_event_type text)
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(
    (select enabled from public.notification_preferences
     where company_id = p_company_id and event_type = p_event_type),
    true
  );
$$;

revoke all on function public.notification_enabled(uuid, text) from public;
revoke execute on function public.notification_enabled(uuid, text) from anon;
grant execute on function public.notification_enabled(uuid, text) to authenticated;
