-- ============================================================================
-- Terms of Service acceptance at company setup.
--
-- The portal's "Create your company" step gains a required "I agree to the
-- Terms of Service" tick box (the terms include a "Use of your name and logo"
-- clause). create_company_and_admin() takes the accepted terms version and
-- records who accepted, when, and which version against the company, plus an
-- audit_log entry.
--
-- terms_version is optional so a portal tab opened before this change can
-- still create a company: the tick box is enforced in the UI and recorded
-- here, not enforced here (same approach as the website's one-off checkout).
-- The old two-argument signature is dropped so there is exactly one function.
-- ============================================================================

alter table public.companies
  add column if not exists terms_accepted_at timestamptz,
  add column if not exists terms_accepted_by uuid references auth.users (id) on delete set null,
  add column if not exists terms_version text;

comment on column public.companies.terms_accepted_at is
  'When the company admin ticked "I agree to the Terms of Service" at company setup. NULL for companies created before 2026-11-05.';
comment on column public.companies.terms_version is
  'Version of the Terms of Service accepted at company setup, e.g. 2026-11.';

drop function if exists public.create_company_and_admin(text, text);

create or replace function public.create_company_and_admin(
  company_name text,
  company_domain text default null,
  terms_version text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_company_id uuid;
  caller_email text;
  accepted_version text := nullif(btrim(terms_version), '');
begin
  if auth.uid() is null then
    raise exception 'Must be authenticated';
  end if;

  if exists (select 1 from public.users where id = auth.uid()) then
    raise exception 'User already belongs to a company';
  end if;

  select email into caller_email from auth.users where id = auth.uid();

  insert into public.companies (name, domain, terms_accepted_at, terms_accepted_by, terms_version)
  values (
    company_name,
    company_domain,
    case when accepted_version is not null then now() end,
    case when accepted_version is not null then auth.uid() end,
    left(accepted_version, 32)
  )
  returning id into new_company_id;

  insert into public.users (id, company_id, email, role, status)
  values (auth.uid(), new_company_id, caller_email, 'company_admin', 'active');

  perform public.log_audit(auth.uid(), 'company.create_self_serve', 'companies', new_company_id, null,
    jsonb_build_object('name', company_name, 'terms_version', left(accepted_version, 32)));

  begin
    perform public.grant_signup_promo(new_company_id, auth.uid());
  exception when others then
    raise warning 'grant_signup_promo failed for company %: %', new_company_id, sqlerrm;
  end;

  return new_company_id;
end;
$$;

-- CREATE FUNCTION hands EXECUTE to PUBLIC by default; keep it authenticated-only
-- (internal_function_grant_leaks allows create_company_and_admin for authenticated).
revoke execute on function public.create_company_and_admin(text, text, text) from public, anon;
grant execute on function public.create_company_and_admin(text, text, text) to authenticated;
