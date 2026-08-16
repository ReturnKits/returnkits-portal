-- SECURITY FIX, second round: a full security-audit-readiness review (user
-- asked "would this app pass an enterprise security audit?") found five MORE
-- SECURITY DEFINER functions with leaked anon/authenticated EXECUTE grants,
-- on top of the six already fixed once in
-- 20260813170000_lock_down_leaked_internal_function_grants.sql. Same root
-- cause, recurring a sixth time: every migration that ships a new or
-- replaced SECURITY DEFINER function needs an explicit
-- `revoke execute ... from anon, authenticated`, and `revoke all from
-- public` alone does not do this -- Supabase grants EXECUTE on every new
-- public-schema function to anon/authenticated by default, independent of
-- `public` role grants.
--
-- Confirmed empirically against pg_proc/information_schema.routine_privileges
-- on the hosted project before writing this migration:
--
--   trigger_scheduled_tracking_poll()  -- anon, authenticated, NO internal
--     role check in its body at all. Worst finding this round: any caller
--     with just the public anon key could have triggered an unlimited
--     number of Sendcloud tracking polls against every eligible order,
--     live-exploitable exactly like get_sendcloud_webhook_secret() was the
--     first time around.
--   create_internal_order(...)  -- anon, authenticated re-leaked. Already
--     has an internal `auth.role() = 'service_role'` guard in its body (not
--     actually exploitable), but re-leaked because the credit-redemption
--     and race-condition-serialization migrations
--     (20260813180000/20260813190000) each replaced this function without
--     re-applying the revoke from 20260813170000 -- CREATE OR REPLACE
--     FUNCTION does not preserve a prior migration's explicit revoke once
--     the function body (and therefore the migration that shipped it) has
--     moved on; the revoke has to travel with every migration that touches
--     the function, not just the one that introduced it.
--   create_order(...)  -- anon leaked (authenticated is intentionally kept
--     -- this is the one function in this list a signed-in company user is
--     meant to call directly). Same re-leak mechanism as
--     create_internal_order above.
--   on_order_dispatched_send_email()  -- anon, authenticated, NO internal
--     check -- a trigger function, never meant to be called directly by
--     anyone; not actually exploitable as a webhook-forgery vector (it
--     doesn't take caller-controlled parameters, it fires off the trigger
--     row), but locked down for defense-in-depth consistency.
--   on_order_paid_send_confirmation()  -- same shape/severity as the above.
--
-- Every other internal-only function was re-checked against the current
-- pg_proc/routine_privileges state and confirmed still correctly locked
-- down from the first round -- this migration closes every new gap found,
-- not a partial fix.

revoke execute on function public.create_order(
  text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean,
  text, text, text, text, text, text, text
) from anon;

revoke execute on function public.create_internal_order(
  uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean,
  text, text, text, text, text, text, text
) from anon, authenticated;

revoke execute on function public.on_order_dispatched_send_email()
  from anon, authenticated;

revoke execute on function public.on_order_paid_send_confirmation()
  from anon, authenticated;

revoke execute on function public.trigger_scheduled_tracking_poll()
  from anon, authenticated;

-- ----------------------------------------------------------------------------
-- internal_function_grant_leaks rebuilt: this bug class has now recurred six
-- times across this project's history, five of them because a hand-
-- maintained list of function names (whether the fixed
-- internalOnlyFunctions array in tests/rls.test.ts, or just "remember to
-- revoke on every new function") depends on someone remembering to update it
-- every time. The view itself was the weak link, not the revokes -- it only
-- ever checked the specific names it was told to check.
--
-- Rebuilt to be self-maintaining: driven directly by pg_proc.prosecdef
-- (every SECURITY DEFINER function in the public schema, automatically,
-- present or future) rather than a curated name list, minus a short
-- explicit allowlist of the handful of functions genuinely meant to be
-- called directly by a signed-in portal user (authenticated only -- anon
-- still isn't allowed to call any of these). A future SECURITY DEFINER
-- function that leaks a grant will show up here with zero test-file or
-- migration maintenance required, closing the actual gap rather than
-- another instance of the same symptom.
--
-- Note: `create or replace view` cannot be used here -- changing the output
-- column types (this rebuild reads proname/pg_proc directly rather than
-- information_schema's sql_identifier-typed columns) raises
-- "cannot change data type of view column" -- hence drop + create.
drop view if exists public.internal_function_grant_leaks;

create view public.internal_function_grant_leaks as
select p.proname as routine_name, rp.grantee
from information_schema.routine_privileges rp
join pg_proc p on p.proname = rp.routine_name::name
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and rp.routine_schema = 'public'
  and rp.privilege_type = 'EXECUTE'
  and rp.grantee = any (array['anon', 'authenticated'])
  and p.prosecdef = true
  and not (
    rp.grantee = 'authenticated'
    and rp.routine_name = any (array[
      'create_order', 'accept_invite', 'confirm_received', 'create_bundle', 'create_company_and_admin'
    ])
  );

-- ----------------------------------------------------------------------------
-- Attempted, deliberately non-fatal: move pg_net out of the public schema
-- (Supabase's own security advisor flags any extension left in `public` as
-- a WARN, since it's writable by any role with CREATE on the schema).
-- Confirmed safe to attempt: the extension's actually-callable functions
-- (net.http_post, net.http_get) already live in their own `net` schema, not
-- `public` -- the extension's public-schema registration is metadata only --
-- and every function in this project that calls net.http_post already
-- includes `extensions` in its own search_path, so the move (if it
-- succeeded) would not change call resolution anywhere. Wrapped in an
-- exception handler because this hosted Supabase project's pg_net version
-- is expected to reject the ALTER (a known limitation on some managed
-- versions) -- if so, this is a residual low-severity advisor WARN to
-- accept or revisit manually via the dashboard, not a blocker.
do $$
begin
  alter extension pg_net set schema extensions;
exception when others then
  raise notice 'pg_net schema move skipped (likely unsupported on this managed Postgres version): %', sqlerrm;
end $$;
