-- ============================================================================
-- Phase 1: Foundations — companies, users, invites, audit_log, roles.
-- Tenant isolation via RLS. See docs/returnkits-portal-architecture.md §3, §9.
--
-- This is the most important migration in the codebase. Every later phase
-- assumes tenant isolation here is correct. Do not weaken any policy in this
-- file without re-running the RLS test suite in tests/rls.test.ts.
-- ============================================================================

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- roles — a lookup table, not a TypeScript union or a bare CHECK enum, so
-- adding a role later is a data change, not a deploy (architecture §9.2).
-- ----------------------------------------------------------------------------
create table public.roles (
  name text primary key,
  scope text not null check (scope in ('company', 'internal')),
  description text not null
);

insert into public.roles (name, scope, description) values
  ('company_admin', 'company', 'Full control within their own company: manage users, invites, billing.'),
  ('company_member', 'company', 'Standard member within their own company: places orders, views company data.'),
  ('internal_admin', 'internal', 'ReturnKits staff, cross-company access, privileged mutations, MFA required.'),
  ('internal_ops', 'internal', 'ReturnKits staff, cross-company read + fulfilment actions.');

-- ----------------------------------------------------------------------------
-- companies
-- ----------------------------------------------------------------------------
create table public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  -- Descriptive metadata ONLY. Company joining is invite-only (signed,
  -- single-use, expiring tokens — see invites below). NEVER consult this
  -- column in an authorization check, RLS policy, or permission function.
  -- Two companies claiming the same domain (e.g. gmail.com) is exactly the
  -- bug this rule prevents — see docs/returnkits-base44-audit.md.
  domain text,
  billing_email text,
  address_line1 text,
  address_line2 text,
  city text,
  postcode text,
  country text not null default 'GB',
  vat_number text,
  stripe_customer_id text,
  status text not null default 'active' check (status in ('active', 'suspended')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- users — the app-facing profile row. Separate from auth.users, which
-- Supabase Auth owns. A row here is only created once company_id is known
-- (via create_company_and_admin or accept_invite below), which is what lets
-- company_id be NOT NULL for company-scoped roles without a chicken-and-egg
-- problem at signup.
--
-- internal_admin / internal_ops have company_id = NULL by design — they
-- carry no tenant restriction (architecture §3). This is why company_id
-- itself is nullable at the column level, with the trigger below enforcing
-- the real rule: NOT NULL for company roles, NULL for internal roles.
-- ----------------------------------------------------------------------------
create table public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  company_id uuid references public.companies(id) on delete restrict,
  email text not null,
  role text not null references public.roles(name),
  status text not null default 'active' check (status in ('invited', 'active', 'revoked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, email)
);

create index idx_users_company_id on public.users(company_id);
create index idx_users_role on public.users(role);

create or replace function public.enforce_user_company_scope()
returns trigger
language plpgsql
as $$
declare
  role_scope text;
begin
  select scope into role_scope from public.roles where name = new.role;

  if role_scope is null then
    raise exception 'Unknown role: %', new.role;
  end if;

  if role_scope = 'company' and new.company_id is null then
    raise exception 'company_id is required for company-scoped role %', new.role;
  end if;

  if role_scope = 'internal' and new.company_id is not null then
    raise exception 'internal role % must not have a company_id', new.role;
  end if;

  return new;
end;
$$;

create trigger trg_enforce_user_company_scope
  before insert or update on public.users
  for each row execute function public.enforce_user_company_scope();

-- ----------------------------------------------------------------------------
-- invites — single-use, expiring, hashed at rest. The raw token is never
-- stored, only its hash — the token itself is the credential (architecture §3).
-- ----------------------------------------------------------------------------
create table public.invites (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  email text not null,
  role text not null references public.roles(name),
  token_hash text not null unique,
  invited_by uuid not null references public.users(id),
  expires_at timestamptz not null default (now() + interval '7 days'),
  accepted_at timestamptz,
  revoked boolean not null default false,
  created_at timestamptz not null default now()
);

create index idx_invites_company_id on public.invites(company_id);
create index idx_invites_email on public.invites(email);

create or replace function public.enforce_invite_role_scope()
returns trigger
language plpgsql
as $$
declare
  role_scope text;
begin
  select scope into role_scope from public.roles where name = new.role;

  if role_scope is distinct from 'company' then
    raise exception 'Invites can only grant company-scoped roles, got %', new.role;
  end if;

  return new;
end;
$$;

create trigger trg_enforce_invite_role_scope
  before insert or update on public.invites
  for each row execute function public.enforce_invite_role_scope();

-- ----------------------------------------------------------------------------
-- audit_log — append-only. No update or delete policy exists for anyone,
-- internal admins included (architecture §9.5). Written in the same
-- transaction as the change it records.
-- ----------------------------------------------------------------------------
create table public.audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.users(id),
  action text not null,
  target_table text not null,
  target_id uuid,
  before jsonb,
  after jsonb,
  created_at timestamptz not null default now()
);

create index idx_audit_log_target on public.audit_log(target_table, target_id);

-- Callable only from within other SECURITY DEFINER functions (no grant to
-- authenticated/anon below) — this is the single write path into audit_log.
create or replace function public.log_audit(
  p_actor_id uuid,
  p_action text,
  p_target_table text,
  p_target_id uuid,
  p_before jsonb,
  p_after jsonb
) returns void
language sql
security definer
set search_path = public
as $$
  insert into public.audit_log (actor_id, action, target_table, target_id, before, after)
  values (p_actor_id, p_action, p_target_table, p_target_id, p_before, p_after);
$$;

revoke all on function public.log_audit(uuid, text, text, uuid, jsonb, jsonb) from public;

-- ----------------------------------------------------------------------------
-- updated_at housekeeping
-- ----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_companies_updated_at
  before update on public.companies
  for each row execute function public.set_updated_at();

create trigger trg_users_updated_at
  before update on public.users
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- JWT claim helpers — used by every RLS policy below. company_id is read
-- straight off the JWT (set by custom_access_token_hook below), never
-- re-queried per row, so RLS stays cheap.
-- ----------------------------------------------------------------------------
create or replace function public.current_company()
returns uuid
language sql
stable
as $$
  select (auth.jwt() ->> 'company_id')::uuid;
$$;

create or replace function public.current_role()
returns text
language sql
stable
as $$
  select auth.jwt() ->> 'role';
$$;

create or replace function public.is_internal()
returns boolean
language sql
stable
as $$
  select public.current_role() in ('internal_admin', 'internal_ops');
$$;

-- ----------------------------------------------------------------------------
-- Custom access token hook — injects company_id and role into every JWT.
-- Must also be enabled in Supabase Dashboard → Authentication → Hooks
-- → Custom Access Token (this migration creates and grants the function;
-- wiring it up as the active hook is a project-level config step, not SQL).
-- ----------------------------------------------------------------------------
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
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
  claims := jsonb_set(claims, '{company_id}', to_jsonb(found_company_id));
  claims := jsonb_set(claims, '{role}', to_jsonb(found_role));

  event := jsonb_set(event, '{claims}', claims);
  return event;
end;
$$;

grant usage on schema public to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;

grant select on public.users to supabase_auth_admin;

create policy "auth_admin_read_users"
  on public.users
  as permissive
  for select
  to supabase_auth_admin
  using (true);

-- ----------------------------------------------------------------------------
-- Privileged signup paths. Both run SECURITY DEFINER so the client never
-- issues a raw INSERT into public.users directly (the RLS policies below
-- deliberately expose no INSERT policy on users for that reason). Both are
-- single-transaction and race-safe — accept_invite in particular uses the
-- same conditional-UPDATE-WHERE-RETURNING pattern the Base44 audit found
-- missing from the free-kit claim (docs/returnkits-base44-audit.md).
-- ----------------------------------------------------------------------------
create or replace function public.create_company_and_admin(
  company_name text,
  company_domain text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_company_id uuid;
  caller_email text;
begin
  if auth.uid() is null then
    raise exception 'Must be authenticated';
  end if;

  if exists (select 1 from public.users where id = auth.uid()) then
    raise exception 'User already belongs to a company';
  end if;

  select email into caller_email from auth.users where id = auth.uid();

  insert into public.companies (name, domain)
  values (company_name, company_domain)
  returning id into new_company_id;

  insert into public.users (id, company_id, email, role, status)
  values (auth.uid(), new_company_id, caller_email, 'company_admin', 'active');

  perform public.log_audit(auth.uid(), 'company.create_self_serve', 'companies', new_company_id, null,
    jsonb_build_object('name', company_name));

  return new_company_id;
end;
$$;

revoke all on function public.create_company_and_admin(text, text) from public;
grant execute on function public.create_company_and_admin(text, text) to authenticated;

create or replace function public.accept_invite(invite_token text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  matched_invite public.invites;
  caller_id uuid := auth.uid();
  caller_email text;
begin
  if caller_id is null then
    raise exception 'Must be authenticated';
  end if;

  if exists (select 1 from public.users where id = caller_id) then
    raise exception 'User already belongs to a company';
  end if;

  select email into caller_email from auth.users where id = caller_id;

  -- Single-statement conditional update: the WHERE clause is the atomicity
  -- guard. Two concurrent accepts of the same token race here, not in
  -- application code, and exactly one wins.
  update public.invites
  set accepted_at = now()
  where token_hash = encode(digest(invite_token, 'sha256'), 'hex')
    and revoked = false
    and accepted_at is null
    and expires_at > now()
  returning * into matched_invite;

  if matched_invite is null then
    raise exception 'Invite is invalid, expired, or already used';
  end if;

  insert into public.users (id, company_id, email, role, status)
  values (caller_id, matched_invite.company_id, caller_email, matched_invite.role, 'active');

  perform public.log_audit(caller_id, 'invite.accept', 'invites', matched_invite.id, null,
    jsonb_build_object('company_id', matched_invite.company_id, 'role', matched_invite.role));

  return matched_invite.company_id;
end;
$$;

revoke all on function public.accept_invite(text) from public;
grant execute on function public.accept_invite(text) to authenticated;

-- ============================================================================
-- Row Level Security
-- ============================================================================
alter table public.roles enable row level security;
alter table public.companies enable row level security;
alter table public.users enable row level security;
alter table public.invites enable row level security;
alter table public.audit_log enable row level security;

-- roles — public lookup data, no tenant scoping.
create policy "roles_select_all"
  on public.roles for select
  to authenticated
  using (true);

-- companies
create policy "companies_select"
  on public.companies for select
  to authenticated
  using (
    public.is_internal()
    or (id = public.current_company() and public.current_company() is not null)
  );

-- Self-serve signup creates a company row before the caller has a
-- company_id claim at all, so this stays permissive at the table level —
-- the real gate is create_company_and_admin(), the only sanctioned path
-- that pairs a company with an admin user.
create policy "companies_insert_self_serve"
  on public.companies for insert
  to authenticated
  with check (true);

create policy "companies_update_admin"
  on public.companies for update
  to authenticated
  using (
    public.is_internal()
    or (id = public.current_company() and public.current_role() = 'company_admin')
  )
  with check (
    public.is_internal()
    or (id = public.current_company() and public.current_role() = 'company_admin')
  );

-- users — this is the policy the RLS test suite exercises most heavily.
create policy "users_select"
  on public.users for select
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );

-- Deliberately no INSERT policy for `authenticated` — see the SECURITY
-- DEFINER functions above. Direct inserts into users are only possible via
-- those functions or the service_role key.

create policy "users_update_admin_or_internal"
  on public.users for update
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_role() = 'company_admin')
  )
  with check (
    public.is_internal()
    or (company_id = public.current_company() and public.current_role() = 'company_admin')
  );

-- invites
create policy "invites_select"
  on public.invites for select
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_company() is not null)
  );

create policy "invites_insert_admin"
  on public.invites for insert
  to authenticated
  with check (
    public.is_internal()
    or (company_id = public.current_company() and public.current_role() = 'company_admin')
  );

create policy "invites_update_admin"
  on public.invites for update
  to authenticated
  using (
    public.is_internal()
    or (company_id = public.current_company() and public.current_role() = 'company_admin')
  )
  with check (
    public.is_internal()
    or (company_id = public.current_company() and public.current_role() = 'company_admin')
  );

-- audit_log — internal-read only. No insert policy for `authenticated`
-- (writes go through log_audit(), called from other SECURITY DEFINER
-- functions). No update or delete policy at all, for anyone — append-only
-- per architecture §9.5.
create policy "audit_log_select_internal"
  on public.audit_log for select
  to authenticated
  using (public.is_internal());
