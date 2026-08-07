-- ============================================================================
-- Phase 2 fix: two lint findings from get_advisors, same class of bug as
-- Phase 1's 150100/150200 hardening migrations.
--
-- 1. enforce_order_reference_immutable() had no `search_path`, same mutable-
--    search-path issue the other trigger functions were fixed for.
--
-- 2. `revoke all ... from public` does NOT revoke Supabase's default
--    per-role grants — new functions are executable by both `anon` and
--    `authenticated` until revoked from those roles explicitly. This is the
--    same gap 150200 closed for accept_invite/create_company_and_admin.
--    next_reference_number() is pure internal plumbing (only ever called
--    from inside create_order()/create_bundle(), where the SECURITY DEFINER
--    owner already has implicit rights) so it loses both anon and
--    authenticated; create_order()/create_bundle() are meant to be called by
--    signed-in customers, so they keep authenticated and lose only anon.
-- ============================================================================

create or replace function public.enforce_order_reference_immutable()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.reference is distinct from old.reference then
    raise exception 'order reference is immutable once issued (was %, attempted %)', old.reference, new.reference;
  end if;
  return new;
end;
$$;

revoke execute on function public.next_reference_number(text) from anon, authenticated;
revoke execute on function public.create_bundle() from anon;
revoke execute on function public.create_order(text, text, uuid, uuid, text, date, date, uuid, text) from anon;
