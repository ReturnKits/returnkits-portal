-- Settings page: admin profile fields (20260813).
--
-- Adds full_name and phone to public.users so a company_admin can maintain
-- their own display name and contact number from the new Settings page.
-- Both nullable -- existing users have neither and shouldn't be forced to
-- backfill before the column exists.
--
-- No RLS policy change needed. users_update_admin_or_internal already
-- permits a company_admin to update any row in their own company (including
-- their own), which is exactly the "admins" scope the user asked for.
-- Company details (name, address, billing_email, vat_number) need no new
-- columns either -- companies_update_admin already covers writing the
-- existing columns, which are the full set the Settings page needs.
--
-- Known gap, not addressed here: there is currently no self-update policy
-- letting a non-admin company_member edit their own users row. Out of scope
-- for this feature (explicitly requested as admin-only) but worth surfacing
-- if company_member self-service is ever wanted.
alter table public.users
  add column if not exists full_name text,
  add column if not exists phone text;

comment on column public.users.full_name is 'Display name, editable by the user''s own company_admin via the Settings page.';
comment on column public.users.phone is 'Contact phone number, editable by the user''s own company_admin via the Settings page.';
