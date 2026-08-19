-- supabase/migrations/20260819120000_fix_public_pseudo_role_grant_leaks.sql
--
-- SEVERE, found live while applying the Enterprise pricing migration
-- (20260819110000) and fixed immediately, same "apply directly to hosted
-- for live-exploitable issues" practice as every prior severity-flagged
-- grant fix in this codebase (20260813170000, 20260816180000).
--
-- Root cause, a variant of the grant-leak bug class this codebase has now
-- hit six-plus times: every prior lockdown migration revoked EXECUTE from
-- anon and authenticated BY NAME, but never from the "PUBLIC" pseudo-role.
-- In Postgres, every role -- anon and authenticated included -- is
-- implicitly a member of PUBLIC, so `GRANT EXECUTE ... TO PUBLIC` is
-- exploitable by anon/authenticated regardless of an explicit REVOKE that
-- names them individually; only `REVOKE ... FROM PUBLIC` actually removes
-- it. A direct scan of every SECURITY DEFINER function's grantees
-- (grouping information_schema.routine_privileges by whether "PUBLIC" is
-- present) found this had recurred on four functions:
--
--   - trigger_scheduled_tracking_poll() -- the WORST finding, again: this is
--     the exact function the 20260816180000 migration already flagged as
--     "SEVERE ... live-exploitable by anyone holding just the public anon
--     key to trigger unlimited Sendcloud polls" and supposedly fixed. That
--     fix's `revoke ... from anon` never touched the PUBLIC grant
--     underneath it, so the same live exploit path was open the entire
--     time since 20260816, just underneath a revoke that looked complete.
--   - on_order_dispatched_send_email(), on_order_paid_send_confirmation()
--     -- lower severity (no caller-controlled params, used as AFTER UPDATE
--     triggers, not meaningfully exploitable via direct RPC call), but
--     locked down for the same defense-in-depth reasoning the 20260816
--     migration already applied to these two -- that reasoning is only
--     actually delivered once PUBLIC is revoked too.
--   - create_order() -- allowlisted (a signed-in portal user is meant to
--     call it directly), but the allowlist was only ever meant to cover
--     'authenticated' access, never 'PUBLIC'/anon -- the function's own
--     internal `current_company()` null-check happens to make an anon call
--     fail safely today, but granting PUBLIC was never the intent, so it's
--     tightened here too: 'authenticated' stays granted, 'PUBLIC' is
--     revoked.
--
-- create_internal_order's own PUBLIC leak was found and fixed in the
-- companion migration 20260819110000, applied moments before this one.
--
-- internal_function_grant_leaks (the standing regression view/test added
-- 20260816) only ever checked routine_privileges for anon/authenticated
-- grantees, never PUBLIC -- so it did not catch this. Extending that view's
-- query to also flag a PUBLIC grantee closes the actual detection gap, not
-- just this one instance of it. The allowlist exception (create_order,
-- accept_invite, confirm_received, create_bundle, create_company_and_admin)
-- still only excuses the 'authenticated' grantee, exactly as before --
-- 'PUBLIC' and 'anon' are never excused for any function, allowlisted or
-- not, since none of these five are meant to be callable by a genuinely
-- unauthenticated caller either.

revoke execute on function public.trigger_scheduled_tracking_poll() from public, anon, authenticated;
revoke execute on function public.on_order_dispatched_send_email() from public, anon, authenticated;
revoke execute on function public.on_order_paid_send_confirmation() from public, anon, authenticated;

revoke execute on function public.create_order(
  text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean,
  text, text, text, text, text, text, text
) from public;

-- ---------------------------------------------------------------------
-- Extend the standing leak-detection view to also catch a PUBLIC grantee,
-- not just anon/authenticated -- this exact bug class evaded the view
-- four more times because it only ever checked for the latter two. Same
-- join shape/column names/security_invoker/grant handling as the original
-- (20260816180000_lock_down_second_round_leaked_grants_and_dynamic_check.sql)
-- -- only the grantee filter and the allowlist scoping changed.
-- ---------------------------------------------------------------------
drop view if exists public.internal_function_grant_leaks;

create view public.internal_function_grant_leaks
with (security_invoker = true) as
select
  p.proname as routine_name,
  rp.grantee
from information_schema.routine_privileges rp
join pg_proc p on p.proname = rp.routine_name::name
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'::name
  and rp.routine_schema::name = 'public'::name
  and rp.privilege_type::text = 'EXECUTE'::text
  and rp.grantee::name = any (array['anon'::name, 'authenticated'::name, 'PUBLIC'::name])
  and p.prosecdef = true
  and not (
    rp.grantee::name = 'authenticated'::name
    and rp.routine_name::name = any (array[
      'create_order'::name, 'accept_invite'::name, 'confirm_received'::name,
      'create_bundle'::name, 'create_company_and_admin'::name
    ])
  );

-- Same "no default grants on the view itself" fix already applied once
-- (20260816200000) -- CREATE VIEW resets to Supabase's default public-schema
-- grants, which would otherwise hand anon/authenticated SELECT on the view.
revoke all on public.internal_function_grant_leaks from anon, authenticated, public;
grant select on public.internal_function_grant_leaks to service_role;
