-- ============================================================================
-- Phase 1 fix: two real bugs the RLS test suite caught.
--
-- 1. The hook was writing our app-level role (company_admin, internal_ops,
--    ...) into the JWT's `role` claim. PostgREST reads that exact claim to
--    decide which POSTGRES database role to SET ROLE into for the request —
--    it must stay `authenticated`. Overwriting it caused
--    'role "company_admin" does not exist'. Our custom role now lives under
--    its own `app_role` claim instead, and we no longer touch `role` at all.
--
-- 2. to_jsonb(NULL) returns a SQL NULL, not a JSON null — and jsonb_set is
--    STRICT, so any NULL argument makes the whole call (and everything
--    built on top of it) collapse to NULL. For internal users (no
--    company_id) and brand-new users (no profile row at all yet), this
--    silently corrupted the entire claims object, which is why GoTrue
--    errored on the hook itself rather than just returning wrong data.
--    Fixed by coalescing to an explicit JSON null before calling jsonb_set.
-- ============================================================================

create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  claims jsonb;
  found_company_id uuid;
  found_role text;
begin
  select company_id, role into found_company_id, found_role
  from public.users
  where id = (event ->> 'user_id')::uuid;

  claims := coalesce(event -> 'claims', '{}'::jsonb);
  claims := jsonb_set(claims, '{company_id}', coalesce(to_jsonb(found_company_id), 'null'::jsonb));
  claims := jsonb_set(claims, '{app_role}', coalesce(to_jsonb(found_role), 'null'::jsonb));

  event := jsonb_set(event, '{claims}', claims);
  return event;
end;
$$;

-- current_role() reads the renamed claim. Kept the function name (matches
-- the architecture doc and every RLS policy that calls it) — only the JWT
-- key it reads from changed.
create or replace function public.current_role()
returns text
language sql
stable
set search_path = public
as $$
  select auth.jwt() ->> 'app_role';
$$;
