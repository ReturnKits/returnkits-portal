-- HubSpot signup sync (added 20260904).
-- See CLAUDE.md for full design reasoning. Two pieces:
--   1. get_hubspot_credentials() -- Vault-backed credential lookup, mirrors
--      get_sendcloud_api_credentials()'s exact hardened shape.
--   2. trigger_sync_hubspot_signup() -- AFTER INSERT trigger on companies,
--      mirrors trigger_checkin_notifications()'s exact pg_net.http_post
--      shape, fires the new sync-hubspot-signup Edge Function.

create or replace function public.get_hubspot_credentials()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'vault'
as $$
declare
  v_token text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'get_hubspot_credentials can only be called by the sync-hubspot-signup Edge Function';
  end if;

  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'hubspot_private_app_token';

  return jsonb_build_object('access_token', v_token);
end;
$$;

revoke all on function public.get_hubspot_credentials() from public, anon, authenticated;
grant execute on function public.get_hubspot_credentials() to service_role;

create or replace function public.trigger_sync_hubspot_signup()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'vault', 'extensions'
as $$
declare
  v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'service_role_key';

  if v_key is null then
    raise warning 'trigger_sync_hubspot_signup: service_role_key not found in Vault, skipping';
    return new;
  end if;

  perform net.http_post(
    url := 'https://pzewknoohcqdqrrhwqrs.supabase.co/functions/v1/sync-hubspot-signup',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body := jsonb_build_object('companyId', new.id)
  );

  return new;
end;
$$;

revoke all on function public.trigger_sync_hubspot_signup() from public, anon, authenticated;

drop trigger if exists companies_sync_hubspot_signup on public.companies;
create trigger companies_sync_hubspot_signup
  after insert on public.companies
  for each row
  execute function public.trigger_sync_hubspot_signup();
