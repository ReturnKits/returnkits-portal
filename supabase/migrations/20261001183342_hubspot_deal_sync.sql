-- Backfilled from the hosted project (applied there directly via apply_migration)
-- so a local `db reset` reproduces hosted.
-- HubSpot deal sync (website forms + Stripe payments -> ReturnKits Sales pipeline).
-- Secrets live in Vault, read only by service_role via this RPC.
create or replace function public.get_hubspot_sync_secrets()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'vault'
as $$
declare
  v_token text;
  v_form_secret text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'get_hubspot_sync_secrets can only be called by the hubspot-*-sync Edge Functions';
  end if;
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'hubspot_private_app_token';
  select decrypted_secret into v_form_secret from vault.decrypted_secrets where name = 'netlify_form_webhook_secret';
  return jsonb_build_object('hubspot_token', v_token, 'form_webhook_secret', v_form_secret);
end;
$$;

revoke all on function public.get_hubspot_sync_secrets() from public, anon, authenticated;
grant execute on function public.get_hubspot_sync_secrets() to service_role;

-- Daily trigger for the abandoned-checkout chaser (mirrors trigger_scheduled_tracking_poll).
create or replace function public.trigger_hubspot_abandoned_checkouts()
returns void
language plpgsql
security definer
set search_path to 'public', 'vault', 'extensions'
as $$
declare
  v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'service_role_key';
  if v_key is null then
    raise warning 'trigger_hubspot_abandoned_checkouts: service_role_key not found in Vault, skipping run';
    return;
  end if;
  perform net.http_post(
    url := 'https://pzewknoohcqdqrrhwqrs.supabase.co/functions/v1/hubspot-abandoned-checkouts',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body := '{}'::jsonb
  );
end;
$$;

revoke all on function public.trigger_hubspot_abandoned_checkouts() from public, anon, authenticated;

-- 07:00 UTC = 08:00 UK (BST)
select cron.schedule('hubspot-abandoned-checkouts-daily', '0 7 * * *', 'select public.trigger_hubspot_abandoned_checkouts();');
