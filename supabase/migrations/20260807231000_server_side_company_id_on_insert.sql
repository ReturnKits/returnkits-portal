-- ============================================================================
-- Bug: "No company on your session yet" when adding an employee/address.
--
-- Root cause: employees.tsx / addresses.tsx insert directly (Phase 2 design
-- note: "no money or concurrency concern here, unlike orders" -- unlike
-- create_order()/create_bundle(), there was never a SECURITY DEFINER RPC
-- computing company_id server-side). Both forms read company_id out of the
-- CLIENT'S OWN JWT (src/lib/session.ts, decodePortalClaims) and refuse to
-- submit if it's missing.
--
-- That JWT claim is set once, at token-mint time, by the custom access
-- token hook. A user who just completed create_company_and_admin() gets an
-- explicit supabase.auth.refreshSession() call to pick up the new claim
-- immediately -- but ANY other reason the browser is holding a slightly
-- stale token (backgrounded tab delaying the auto-refresh timer, a second
-- open tab, etc) reproduces the exact same symptom: the database is
-- correct, RLS would happily allow the insert, but the client refuses to
-- even try because it doesn't trust its own (possibly stale) copy of a
-- fact the server already knows for certain.
--
-- Fix: stop asking the client to know its own company_id at all. Same
-- pattern as create_order()/create_bundle() (compute company_id from
-- current_company(), a fresh read of auth.jwt() at execution time, not a
-- value decoded from a cached token client-side) -- just implemented as a
-- BEFORE INSERT trigger instead of a wrapping RPC, since these are plain
-- CRUD tables with no money/concurrency logic to justify a full RPC.
-- ============================================================================

create or replace function public.set_company_id_from_session()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if public.is_internal() then
    -- internal_admin/internal_ops have current_company() = null by design
    -- (architecture §3, no tenant restriction) -- they act on behalf of a
    -- specific company (e.g. from Retool later), so they must supply
    -- company_id explicitly. Leave their input alone, just require it.
    if new.company_id is null then
      raise exception 'company_id is required when inserting as internal staff';
    end if;
    return new;
  end if;

  if public.current_company() is null then
    raise exception 'Your account is not attached to a company yet.';
  end if;

  -- Always the caller's own company, regardless of what the client sent --
  -- this is what removes the client's need to know/guess its own
  -- company_id before submitting, and closes off any possibility of a
  -- client attempting to insert a row into a DIFFERENT company_id than
  -- their own (the with_check policy already blocked that, this makes it
  -- moot rather than merely blocked).
  new.company_id := public.current_company();
  return new;
end;
$$;

create trigger trg_employees_set_company_id
  before insert on public.employees
  for each row execute function public.set_company_id_from_session();

create trigger trg_addresses_set_company_id
  before insert on public.addresses
  for each row execute function public.set_company_id_from_session();
