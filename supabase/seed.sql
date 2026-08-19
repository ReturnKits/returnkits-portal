-- Local-dev-only workaround: this machine's local Supabase Postgres image ships a
-- broken default ACL for role "postgres" on schema public (missing SELECT/INSERT/
-- UPDATE/DELETE for anon/authenticated on tables, and no default ACL at all for
-- functions), unlike the correct supabase_admin default ACL and unlike hosted
-- Supabase. Migrations run as "postgres", so every table/function we create
-- inherits the broken (or absent) grants. This re-grants correctly after every
-- db reset. Confirmed via pg_default_acl on 2026-08-19, Supabase CLI 2.115.0.

grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to anon, authenticated, service_role;
grant usage, select on all sequences in schema public to anon, authenticated, service_role;

alter default privileges in schema public
  grant select, insert, update, delete on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant usage, select on sequences to anon, authenticated, service_role;

-- Functions: service_role must always be able to call every internal function.
-- Deliberately NOT granting execute to anon/authenticated here -- Postgres's own
-- PUBLIC-role default already covers untouched functions, and every migration in
-- this project's history that needed to lock a function down did so with an
-- explicit "revoke execute ... from anon, authenticated". Blanket-granting here
-- would silently undo every one of those revokes (found this the hard way: it
-- re-opened get_resend_webhook_secret, orders_needing_checkin,
-- record_credit_purchase, and record_card_setup on 2026-08-19).
grant execute on all functions in schema public to service_role;
alter default privileges in schema public
  grant execute on functions to service_role;

-- internal_function_grant_leaks is a view, and the blanket table grant above
-- would otherwise hand anon/authenticated SELECT on it too -- directly undoing
-- its own dedicated lockdown migration
-- (20260816200000_revoke_default_grants_on_grant_leaks_view.sql). Re-revoke
-- explicitly, every reset, after the blanket grant above.
revoke select on public.internal_function_grant_leaks from anon, authenticated, public;

-- Explicitly re-grant execute to authenticated on the small allowlist of functions
-- meant to be called directly by a signed-in portal user (same allowlist as
-- internal_function_grant_leaks' own exclusion list, documented in CLAUDE.md).
-- Dynamic by name (not a fixed signature) so it self-heals if any of these
-- functions' argument lists change again in a future migration.
do $$
declare
  fn record;
begin
  for fn in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'create_order', 'accept_invite', 'confirm_received',
        'create_bundle', 'create_company_and_admin'
      )
  loop
    execute format('grant execute on function %s to authenticated', fn.sig);
  end loop;
end $$;