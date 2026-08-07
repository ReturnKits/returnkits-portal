-- ============================================================================
-- Fix: users_select required company_id = current_company(), which itself
-- depends on the JWT already carrying the correct company_id claim. That
-- claim is only set by the custom access token hook reading this exact row,
-- so it's a circular dependency: a user can't reliably read their own
-- profile to discover "do I have a company yet" until a token has cycled
-- through with the claim already present.
--
-- Observed in production: a user completes create_company_and_admin()
-- successfully (confirmed server-side, SECURITY DEFINER bypasses RLS), but
-- the client's own `select id from users where id = auth.uid()` check --
-- used by both src/routes/_authenticated/route.tsx and
-- src/routes/auth.callback.tsx to decide "onboarded or not" -- keeps
-- returning zero rows on subsequent page loads/logins, sending them back to
-- the company-creation form in a loop even though their company exists.
--
-- Fix: let a user always read their own row directly by id, independent of
-- company scoping. This can never leak cross-tenant data -- you already know
-- your own auth.uid() -- and it breaks the circular claim dependency for the
-- one check the whole onboarding flow hinges on.
-- ============================================================================

alter policy "users_select"
  on public.users
  using (
    public.is_internal()
    or id = auth.uid()
    or (company_id = public.current_company() and public.current_company() is not null)
  );
