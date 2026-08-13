-- Fix: set_company_id_from_session() rejects service_role inserts entirely.
--
-- Root cause: BEFORE INSERT triggers run even for connections that bypass
-- RLS (service_role has BYPASSRLS at the Postgres role level -- that only
-- skips RLS *policies*, never triggers). The trigger's own gate,
-- `if public.is_internal() then ... end if`, only recognises the two
-- *authenticated-user* internal roles (internal_admin/internal_ops, set by
-- the custom access token hook on an ordinary session). A request made with
-- the service_role key carries a bare `{"role":"service_role"}` JWT with no
-- company_id claim and isn't internal_admin/internal_ops either, so it falls
-- through to `current_company() is null` and raises 'Your account is not
-- attached to a company yet.' on every single service-role insert into
-- employees/addresses, unconditionally.
--
-- In production this never fires -- Lovable's portal always inserts as the
-- authenticated company user (real company_id claim), and per CLAUDE.md
-- rule 7 Retool never writes straight to tables, always through the app's
-- API. But it breaks any legitimate service-role write, most immediately
-- the RLS test suite's own fixture setup (`adminClient.from("employees")
-- .insert(...)`, `adminClient.from("addresses").insert(...)`), which is
-- exactly the same shape of admin-arranges-fixture insert the suite already
-- does safely against every OTHER table. Confirmed by tracing the exact
-- error text ("Your account is not attached to a company yet.") to this one
-- function -- create_order()'s own equivalent guard raises a different
-- message ('Must belong to a company'), and no other is_internal() call
-- site in the schema gates trigger *behaviour* the way this one does (every
-- other usage is inside an RLS policy's USING clause, which service_role
-- never even evaluates).
--
-- Fix: treat service_role the same as internal_admin/internal_ops -- it has
-- no company_id claim to derive from either, so it must supply company_id
-- explicitly, same requirement, same error if omitted. This mirrors the
-- existing auth.role() = 'service_role' check already used in
-- create_internal_order() elsewhere in this schema.

create or replace function public.set_company_id_from_session()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if public.is_internal() or auth.role() = 'service_role' then
    -- internal_admin/internal_ops (authenticated internal staff) and
    -- service_role (test fixtures, backend scripts) all lack a company_id
    -- JWT claim by design -- they act on behalf of a specific company, so
    -- they must supply company_id explicitly. Leave their input alone,
    -- just require it.
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
