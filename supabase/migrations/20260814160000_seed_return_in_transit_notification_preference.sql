-- Extends seed_default_notification_preferences() to include the new
-- 'return_in_transit' event type (added in
-- 20260814150000_add_return_in_transit_comms_type.sql) and backfills a row
-- for every existing company, enabled by default -- same as the original 4
-- event types.
--
-- Gap found while writing behaviour tests for the return_in_transit email:
-- the earlier migration only widened the two CHECK constraints
-- (communication_log_type_check, notification_preferences_event_type_check)
-- but never touched this trigger function, which hardcodes its own list of
-- event types via unnest(array[...]). Without this fix, no company -- new
-- or existing -- ever gets a notification_preferences row for
-- 'return_in_transit': notification_enabled() would still return true for
-- it via its own "no row -> default true" fallback (proven in
-- tests/rls.test.ts), so the email itself was never actually at risk of
-- silently failing to send -- but there would be no row for a company admin
-- to toggle off in the Settings UI, which is inconsistent with how the
-- other 4 event types work and was never a deliberate scope decision, just
-- an oversight in the original migration.
--
-- No Lovable UI work is bundled with this fix -- whatever renders the
-- existing mute toggles already reads notification_preferences rows
-- directly, so it picks up the 5th row automatically once seeded; nothing
-- to change on that side.

create or replace function public.seed_default_notification_preferences()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  insert into public.notification_preferences (company_id, event_type, enabled)
  select new.id, event_type, true
  from unnest(array['order_confirmation', 'dispatched', 'checkin_sent', 'checkin_received', 'return_in_transit']) as event_type
  on conflict (company_id, event_type) do nothing;
  return new;
end;
$$;

-- Backfill: every company that already exists predates this event type and
-- has no row for it yet.
insert into public.notification_preferences (company_id, event_type, enabled)
select id, 'return_in_transit', true
from public.companies
on conflict (company_id, event_type) do nothing;
