-- ============================================================================
-- Phase 5: Resend delivery webhook support.
--
-- CLAUDE.md rule #4: every inbound webhook is signature-verified and
-- idempotent, keyed on the provider's event ID. Resend signs webhooks via
-- Svix (svix-id / svix-timestamp / svix-signature headers, HMAC-SHA256).
-- resend_webhook_events mirrors stripe_webhook_events exactly (event_id,
-- event_type, processed_at) -- same idempotency pattern, different provider.
--
-- suppressed_recipients: best-practice pattern (checked before every send,
-- not left to Resend's own suppression list) -- hard bounces and spam
-- complaints are permanent signals; an address that hard-bounced once will
-- never accept mail again, and continuing to send after a complaint is a
-- deliverability and, for complaints, a compliance problem. Populated only
-- by the resend-webhook function (service_role); no client access.
--
-- communication_log.status gains 'suppressed' -- distinct from 'failed'
-- (a real send attempt that errored) because a suppressed send never hit
-- the network at all.
-- ============================================================================

create table public.resend_webhook_events (
  event_id text primary key,
  event_type text not null,
  processed_at timestamptz not null default now()
);

comment on table public.resend_webhook_events is
  'Idempotency ledger for the Resend delivery webhook, keyed on the svix-id header. Mirrors stripe_webhook_events.';

-- Internal-only: no RLS policies means default-deny for anon/authenticated
-- once RLS is enabled (matches stripe_webhook_events).
alter table public.resend_webhook_events enable row level security;

create table public.suppressed_recipients (
  email text primary key,
  reason text not null check (reason in ('hard_bounce', 'complaint')),
  source_communication_log_id uuid references public.communication_log(id) on delete set null,
  created_at timestamptz not null default now()
);

comment on table public.suppressed_recipients is
  'Recipients who must never be emailed again: hard bounce (address invalid) or spam complaint (compliance requirement). Checked by send-order-email before every send. Populated only by resend-webhook. Never automatically removed -- a manual unsuppress is a deliberate, auditable action, not something this schema exposes yet (no removal path needed at launch volume).';

alter table public.suppressed_recipients enable row level security;

alter table public.communication_log drop constraint communication_log_status_check;
alter table public.communication_log add constraint communication_log_status_check
  check (status in ('queued', 'sent', 'delivered', 'bounced', 'complained', 'failed', 'suppressed'));

-- ---- Vault helper for the webhook signing secret ------------------------
--
-- Same pattern as trigger_send_order_email's service_role_key lookup: the
-- Edge Function calls this via supabase.rpc() using its own service_role
-- client (service_role bypasses the revoke below, same as it already does
-- for notification_enabled) rather than reading a Deno env var, so the
-- secret lives in exactly one place (Vault) regardless of which runtime
-- needs it.
create or replace function public.get_resend_webhook_secret()
returns text
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'resend_webhook_secret';
  return v_secret;
end;
$$;

revoke all on function public.get_resend_webhook_secret() from public;
revoke execute on function public.get_resend_webhook_secret() from anon, authenticated;
