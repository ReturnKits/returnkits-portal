-- Backfilled from the hosted project (applied there directly via apply_migration)
-- so a local `db reset` reproduces hosted.
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
    url := 'https://pzewknoohcqdqrrhwqrs.supabase.co/functions/v1/hubspot-sync/abandoned',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body := '{}'::jsonb
  );
end;
$$;
revoke all on function public.trigger_hubspot_abandoned_checkouts() from public, anon, authenticated;
