-- ============================================================================
-- Phase 5: schedule the check-in nudge job.
--
-- Runs hourly, every day -- deliberately NOT restricted to a UTC business-
-- hours window, because Europe/London shifts between GMT and BST across
-- the year and a fixed UTC cron expression would silently fire an hour
-- early/late for half of it. send-checkin-notifications itself calls
-- within_sending_hours(now()) and no-ops outside 08:00-18:00 Europe/London
-- on a working day -- that check is timezone-correct year-round, unlike
-- the cron schedule. Running hourly and mostly no-op'ing is cheap; getting
-- the schedule itself DST-correct is not worth the complexity.
-- ============================================================================

create or replace function public.trigger_checkin_notifications()
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
    raise warning 'trigger_checkin_notifications: service_role_key not found in Vault, skipping run';
    return;
  end if;

  perform net.http_post(
    url := 'https://pzewknoohcqdqrrhwqrs.supabase.co/functions/v1/send-checkin-notifications',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body := '{}'::jsonb
  );
end;
$$;

revoke all on function public.trigger_checkin_notifications() from public;
revoke execute on function public.trigger_checkin_notifications() from anon, authenticated;

select cron.schedule(
  'checkin-notifications-hourly',
  '0 * * * *',
  $$select public.trigger_checkin_notifications();$$
);
