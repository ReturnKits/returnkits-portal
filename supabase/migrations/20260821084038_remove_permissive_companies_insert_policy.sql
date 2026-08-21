-- Fixes a critical finding from Lovable's security scanner (20260821): the
-- companies_insert_self_serve RLS policy had WITH CHECK (true), so any
-- authenticated user could INSERT a companies row with arbitrary values --
-- e.g. enterprise_pricing_enabled = true, a made-up stripe_customer_id, or
-- arbitrary billing details -- bypassing create_company_and_admin entirely.
--
-- Confirmed via direct inspection before fixing, not guessed:
--   1. create_company_and_admin() is SECURITY DEFINER, owned by `postgres`,
--      and `postgres` has rolbypassrls = true -- so the RPC's own INSERT
--      into public.companies never needed this policy in the first place;
--      BYPASSRLS skips RLS policy evaluation entirely for that role.
--   2. The Lovable portal's signup flow (src/routes/auth.callback.tsx,
--      CreateCompanyForm) only ever calls the create_company_and_admin RPC
--      to create the row, then a plain .update() (gated correctly by the
--      pre-existing companies_update_admin policy) to fill in optional
--      billing fields. There is no direct .from("companies").insert(...)
--      call anywhere in the app code.
-- So this permissive policy had no legitimate caller at all -- pure
-- unnecessary attack surface, safe to drop outright rather than tighten.
--
-- Also revokes the table-level INSERT grant from `authenticated` and `anon`
-- (Supabase's default per-table grant, same root cause as every other
-- leaked-grant incident in this project's history -- grants stay broad by
-- default, RLS was supposed to be the real gate). `service_role`/`postgres`
-- keep their INSERT grant -- BYPASSRLS only skips policy evaluation, not the
-- underlying table privilege check, so create_company_and_admin still needs it.
--
-- Live-verified before and after, via safe rolled-back transactions against
-- the hosted database (not just reasoned about): a direct INSERT as
-- `authenticated` now fails with insufficient_privilege, and
-- create_company_and_admin() still succeeds end to end and returns a real
-- new_company_id, both confirmed with the fix applied.

drop policy if exists companies_insert_self_serve on public.companies;

revoke insert on public.companies from authenticated, anon;
