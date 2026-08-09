-- ============================================================================
-- Phase 5: wire order_confirmation and dispatched emails to fire
-- automatically from the state changes that already happen --
-- record_stripe_payment (payment_status -> paid) and mark_order_dispatched
-- (fulfilment_status -> dispatched). Fired via pg_net (async HTTP from
-- Postgres) rather than making the calling function itself slow/fragile by
-- waiting on an email send inline -- record_stripe_payment and
-- mark_order_dispatched keep working exactly as before even if Resend is
-- down or the email function errors.
--
-- The service_role key is read from Supabase Vault, never hardcoded in SQL
-- (this migration file never contains the actual key value -- see the
-- one-time vault.create_secret command the user runs separately, since I
-- never have the plaintext key myself).
-- ============================================================================

create extension if not exists pg_net;
create extension if not exists pg_cron;

create or replace function public.trigger_send_order_email(p_order_id uuid, p_type text)
returns void
language plpgsql
security definer
set search_path = public, vault, extensions
as $$
declare
  v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'service_role_key';

  if v_key is null then
    -- Don't fail the caller (a payment or dispatch just succeeded) just
    -- because the Vault secret isn't set up yet -- log and move on. Once
    -- the secret exists this starts working with no further deploy needed.
    raise warning 'trigger_send_order_email: service_role_key not found in Vault, skipping send for order % (%)', p_order_id, p_type;
    return;
  end if;

  perform net.http_post(
    url := 'https://pzewknoohcqdqrrhwqrs.supabase.co/functions/v1/send-order-email',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body := jsonb_build_object('orderId', p_order_id, 'type', p_type)
  );
end;
$$;

revoke all on function public.trigger_send_order_email(uuid, text) from public;
revoke execute on function public.trigger_send_order_email(uuid, text) from anon, authenticated;

-- Order confirmation: fires the instant payment_status flips to 'paid'.
create or replace function public.on_order_paid_send_confirmation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.payment_status = 'paid' and (old.payment_status is distinct from 'paid') then
    perform public.trigger_send_order_email(new.id, 'order_confirmation');
  end if;
  return new;
end;
$$;

create trigger trg_order_paid_send_confirmation
  after update on public.orders
  for each row execute function public.on_order_paid_send_confirmation();

-- Dispatched: fires the instant fulfilment_status flips to 'dispatched'
-- (i.e. right after mark_order_dispatched's own UPDATE commits).
create or replace function public.on_order_dispatched_send_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.fulfilment_status = 'dispatched' and (old.fulfilment_status is distinct from 'dispatched') then
    perform public.trigger_send_order_email(new.id, 'dispatched');
  end if;
  return new;
end;
$$;

create trigger trg_order_dispatched_send_email
  after update on public.orders
  for each row execute function public.on_order_dispatched_send_email();
