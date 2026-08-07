-- ============================================================================
-- Phase 1 follow-up: accept_invite() and create_company_and_admin() both
-- guard internally against a null auth.uid() (anon calls fail safely with
-- an exception either way), but the linter is right that anon shouldn't
-- have the grant in the first place — defense in depth, not just a working
-- guard clause. Restrict both to `authenticated` only.
-- ============================================================================

revoke execute on function public.accept_invite(text) from anon;
revoke execute on function public.create_company_and_admin(text, text) from anon;
