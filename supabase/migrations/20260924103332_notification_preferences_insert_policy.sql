-- Backfilled from the hosted project (applied there directly via apply_migration)
-- so a local `db reset` reproduces hosted.
-- Fix: Settings page's "Notifications" card upserts all 4 (well, the app's own 4 of the
-- 5 possible) event_type rows on every save. notification_preferences previously had only
-- SELECT and UPDATE RLS policies for `authenticated` (company_id = current_company()) - no
-- INSERT policy - so any company missing a row for one of the event types (e.g. a company
-- created before a given event type existed, or one whose seed trigger never ran for some
-- reason) got "new row violates row-level security policy" the moment they saved Settings.
-- Same company-scoping shape as the table's own existing SELECT/UPDATE policies, and the
-- same shape used elsewhere in this project for company-admin-writable tables (companies,
-- users). The pre-existing UNIQUE(company_id, event_type) constraint means a company can
-- never insert a duplicate/conflicting row for another company's data - with_check ties the
-- insert to their own company_id only, matching current_company()'s JWT-derived value.
create policy notification_preferences_insert_own_company
  on public.notification_preferences
  for insert
  to authenticated
  with check (company_id = current_company());
