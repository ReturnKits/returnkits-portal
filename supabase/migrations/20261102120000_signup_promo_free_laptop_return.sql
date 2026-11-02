-- Free first laptop return -- sign-up promo (20261102). Builds the
-- unbuilt §22 "Free Kit Promo" from docs/returnkits-portal-architecture.md,
-- with the scope confirmed with the user 20261102:
--
--   * One free Laptop credit (worth £65) per company, granted automatically
--     inside create_company_and_admin() -- i.e. at company setup. Existing
--     companies never get one (nothing back-fills; the grant only ever
--     happens at creation time).
--   * Work email only: the signing-up user's email must be verified and its
--     domain must not be in blocked_email_domains (free-mail + disposable).
--     One grant per email domain, so a second company on the same domain
--     gets nothing. NOTE: this is an abuse *signal* for a marketing grant,
--     not authorization -- companies.domain stays unused for access control
--     exactly as CLAUDE.md requires. Never reuse email_domain for access.
--   * Capped at promotions.max_grants (20) across all companies, behind an
--     admin on/off switch (promotions.enabled, toggled only via
--     set_promotion_enabled from Retool). Seeded DISABLED -- deploying this
--     migration changes nothing for customers until staff switch it on.
--     Switching it off stops new grants; already-issued credits are honoured
--     until they expire.
--   * Valid 60 days. Only usable on a standard UK-to-UK laptop return
--     (service_type 'return', drop-off, recipient and return address both
--     GB). Enhanced Cover stays chargeable (paid-cover path supported).
--   * Cancelling a promo-paid order gives the credit back with its ORIGINAL
--     expiry (never extended); if it has already expired by then, it is
--     marked expired instead. This deliberately overrides §22's "forfeit"
--     rule -- user decision 20261102.
--
-- Ledger shape: promo rows live in the same append-only credit_ledger,
-- tagged with promotion_id (null for every existing and every purchased
-- row). Purchased balances are now always computed with
-- `promotion_id is null` (purchased_credit_balance()), so a promo grant can
-- never inflate, and a promo expiry can never reduce, a purchased balance.
-- For promo rows balance_after is the promo-only balance (1 or 0).
--
-- Redemption needs no new create_order param (avoids the PGRST203 overload
-- trap documented in CLAUDE.md): when p_pay_with_credit is true and the
-- order qualifies, the promo credit is spent first, under the same
-- company+kit advisory lock every redemption already takes; anything that
-- doesn't qualify falls through to purchased credits unchanged. Single use
-- is a row lock plus a conditional status flip, never read-then-write.
--
-- Abuse signal at redemption: the recipient and return addresses are
-- normalised (promo_address_key) and compared with every other company's
-- redeemed promo; a match sets address_flagged for staff to review in
-- Retool. Flag only, never a block (user decision 20261102).

-- ----------------------------------------------------------------------------
-- Tables
-- ----------------------------------------------------------------------------

create table public.promotions (
  id text primary key,
  label text not null,
  enabled boolean not null default false,
  kit_type_id text not null references public.kit_types(id),
  validity_days integer not null check (validity_days > 0),
  max_grants integer not null check (max_grants >= 0),
  first_enabled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.promotions enable row level security;

create policy promotions_select_internal on public.promotions
  for select to authenticated
  using (public.is_internal());

insert into public.promotions (id, label, enabled, kit_type_id, validity_days, max_grants)
values ('first_laptop_free', 'Free first laptop return (sign-up offer)', false, 'laptop', 60, 20);

-- Free-mail and disposable domains that don't count as a work email.
-- Internal-only; staff add to it directly in Retool if a new one turns up.
create table public.blocked_email_domains (
  domain text primary key check (domain = lower(domain)),
  kind text not null check (kind in ('free_mail', 'disposable'))
);

alter table public.blocked_email_domains enable row level security;

create policy blocked_email_domains_select_internal on public.blocked_email_domains
  for select to authenticated
  using (public.is_internal());

insert into public.blocked_email_domains (domain, kind) values
  ('gmail.com', 'free_mail'), ('googlemail.com', 'free_mail'),
  ('outlook.com', 'free_mail'), ('outlook.co.uk', 'free_mail'),
  ('hotmail.com', 'free_mail'), ('hotmail.co.uk', 'free_mail'),
  ('live.com', 'free_mail'), ('live.co.uk', 'free_mail'),
  ('msn.com', 'free_mail'), ('windowslive.com', 'free_mail'),
  ('yahoo.com', 'free_mail'), ('yahoo.co.uk', 'free_mail'), ('ymail.com', 'free_mail'),
  ('rocketmail.com', 'free_mail'),
  ('icloud.com', 'free_mail'), ('me.com', 'free_mail'), ('mac.com', 'free_mail'),
  ('aol.com', 'free_mail'), ('aol.co.uk', 'free_mail'),
  ('proton.me', 'free_mail'), ('protonmail.com', 'free_mail'), ('pm.me', 'free_mail'),
  ('gmx.com', 'free_mail'), ('gmx.co.uk', 'free_mail'), ('mail.com', 'free_mail'),
  ('zoho.com', 'free_mail'), ('yandex.com', 'free_mail'), ('tutanota.com', 'free_mail'),
  ('fastmail.com', 'free_mail'), ('hey.com', 'free_mail'),
  ('btinternet.com', 'free_mail'), ('btopenworld.com', 'free_mail'),
  ('sky.com', 'free_mail'), ('virginmedia.com', 'free_mail'), ('talktalk.net', 'free_mail'),
  ('ntlworld.com', 'free_mail'), ('blueyonder.co.uk', 'free_mail'),
  ('tiscali.co.uk', 'free_mail'), ('plus.net', 'free_mail'),
  ('mailinator.com', 'disposable'), ('guerrillamail.com', 'disposable'),
  ('guerrillamail.info', 'disposable'), ('sharklasers.com', 'disposable'),
  ('10minutemail.com', 'disposable'), ('temp-mail.org', 'disposable'),
  ('tempmail.com', 'disposable'), ('throwawaymail.com', 'disposable'),
  ('yopmail.com', 'disposable'), ('trashmail.com', 'disposable'),
  ('getnada.com', 'disposable'), ('maildrop.cc', 'disposable'),
  ('dispostable.com', 'disposable'), ('fakeinbox.com', 'disposable'),
  ('mintemail.com', 'disposable'), ('mohmal.com', 'disposable'),
  ('emailondeck.com', 'disposable'), ('spamgourmet.com', 'disposable'),
  ('mailnesia.com', 'disposable'), ('tempinbox.com', 'disposable'),
  ('burnermail.io', 'disposable'), ('33mail.com', 'disposable');

alter table public.credit_ledger
  add column promotion_id text references public.promotions(id),
  add column expires_at timestamptz;

-- Expiry only ever applies to promo credits. Purchased credits never
-- expire (§22: expiring paid-for credits is a bad look and an unfair-terms
-- risk).
alter table public.credit_ledger add constraint credit_ledger_expiry_only_on_promo
  check (expires_at is null or promotion_id is not null);

-- Promo rows are only ever adjustments (grant / restore / expiry) or
-- redemptions, never purchases.
alter table public.credit_ledger add constraint credit_ledger_promo_never_purchase
  check (promotion_id is null or transaction_type in ('adjustment', 'redemption'));

create index credit_ledger_promotion_id_idx on public.credit_ledger (promotion_id) where promotion_id is not null;

create table public.promotion_grants (
  id uuid primary key default gen_random_uuid(),
  promotion_id text not null references public.promotions(id),
  company_id uuid not null references public.companies(id),
  email_domain text not null,
  status text not null default 'issued' check (status in ('issued', 'redeemed', 'expired')),
  granted_at timestamptz not null default now(),
  expires_at timestamptz not null,
  grant_ledger_id uuid not null references public.credit_ledger(id),
  redeemed_order_id uuid references public.orders(id),
  redeemed_at timestamptz,
  expired_at timestamptz,
  recipient_address_key text,
  return_address_key text,
  address_flagged boolean not null default false,
  address_flag_detail jsonb,
  -- The two database-enforced "one per business" rules.
  unique (promotion_id, company_id),
  unique (promotion_id, email_domain),
  check ((status = 'redeemed') = (redeemed_order_id is not null))
);

create index promotion_grants_company_idx on public.promotion_grants (company_id);
create index promotion_grants_issued_expiry_idx on public.promotion_grants (expires_at) where status = 'issued';

alter table public.promotion_grants enable row level security;

-- Same shape as credit_ledger_select: a company reads only its own grant
-- (the dashboard banner needs status + expires_at), staff read all. No
-- insert/update/delete policy -- every write goes through a function below.
create policy promotion_grants_select on public.promotion_grants
  for select to authenticated
  using (public.is_internal() or (company_id = public.current_company() and public.current_company() is not null));

-- ----------------------------------------------------------------------------
-- Helpers (plain/invoker functions: they only ever run inside the SECURITY
-- DEFINER RPCs below, and EXECUTE is revoked from every client role)
-- ----------------------------------------------------------------------------

create or replace function public.purchased_credit_balance(p_company_id uuid, p_kit_type_id text)
returns integer
language sql
stable
set search_path to 'public'
as $$
  select coalesce(sum(case when direction = 'credit' then quantity else -quantity end), 0)::integer
  from public.credit_ledger
  where company_id = p_company_id
    and kit_type_id = p_kit_type_id
    and promotion_id is null;
$$;

create or replace function public.promo_address_key(p_line1 text, p_postcode text)
returns text
language sql
immutable
as $$
  select case
    when nullif(trim(p_line1), '') is null or nullif(trim(p_postcode), '') is null then null
    else upper(regexp_replace(p_postcode, '\s', '', 'g')) || '|' || lower(regexp_replace(trim(p_line1), '\s+', ' ', 'g'))
  end;
$$;

-- Same "insufficient balance" exception every redemption path already
-- raised, with a clearer message when the company is holding an unused
-- promo credit that this particular order doesn't qualify for.
create or replace function public.raise_insufficient_credit(p_company_id uuid, p_kit_type_id text, p_balance integer)
returns void
language plpgsql
set search_path to 'public'
as $$
begin
  if exists (
    select 1
    from public.promotion_grants g
    join public.promotions p on p.id = g.promotion_id
    where g.company_id = p_company_id
      and p.kit_type_id = p_kit_type_id
      and g.status = 'issued'
      and g.expires_at > now()
  ) then
    raise exception 'Your free laptop return credit can only be used for a UK laptop return dropped off at a Royal Mail point. You have no purchased % credits for this order.', p_kit_type_id;
  end if;

  raise exception 'Insufficient % credit balance (have %, need 1)', p_kit_type_id, p_balance;
end;
$$;

-- Called from create_company_and_admin() only. Returns 'granted' or the
-- reason it wasn't; every outcome is written to audit_log so staff can see
-- why a signup didn't qualify.
create or replace function public.grant_signup_promo(p_company_id uuid, p_user_id uuid)
returns text
language plpgsql
set search_path to 'public'
as $$
declare
  v_promo public.promotions%rowtype;
  v_email text;
  v_confirmed timestamptz;
  v_domain text;
  v_issued integer;
  v_expires timestamptz;
  v_ledger_id uuid;
  v_grant_id uuid;
  v_reason text;
begin
  -- Row lock serialises every concurrent signup's claim, so the cap, the
  -- per-company rule and the per-domain rule can't be raced. The unique
  -- constraints on promotion_grants are the backstop.
  select * into v_promo from public.promotions where id = 'first_laptop_free' for update;

  if not found or not v_promo.enabled then
    v_reason := 'promotion_disabled';
  else
    select email, email_confirmed_at into v_email, v_confirmed
    from auth.users where id = p_user_id;

    v_domain := lower(split_part(coalesce(v_email, ''), '@', 2));

    if v_confirmed is null then
      v_reason := 'email_not_verified';
    elsif v_domain = '' then
      v_reason := 'no_email_domain';
    elsif exists (select 1 from public.blocked_email_domains where domain = v_domain) then
      v_reason := 'not_a_work_email';
    elsif exists (select 1 from public.promotion_grants where promotion_id = v_promo.id and company_id = p_company_id) then
      v_reason := 'already_granted';
    elsif exists (select 1 from public.promotion_grants where promotion_id = v_promo.id and email_domain = v_domain) then
      v_reason := 'email_domain_already_claimed';
    else
      select count(*) into v_issued from public.promotion_grants where promotion_id = v_promo.id;
      if v_issued >= v_promo.max_grants then
        v_reason := 'promotion_cap_reached';
      end if;
    end if;
  end if;

  if v_reason is not null then
    perform public.log_audit(p_user_id, 'promo.not_granted', 'companies', p_company_id, null,
      jsonb_build_object('promotion_id', 'first_laptop_free', 'reason', v_reason, 'email_domain', v_domain));
    return v_reason;
  end if;

  v_expires := now() + make_interval(days => v_promo.validity_days);

  insert into public.credit_ledger (
    company_id, kit_type_id, transaction_type, direction, quantity,
    balance_after, actor_id, reason, promotion_id, expires_at
  ) values (
    p_company_id, v_promo.kit_type_id, 'adjustment', 'credit', 1,
    1, p_user_id, 'Free first laptop return (sign-up offer)', v_promo.id, v_expires
  )
  returning id into v_ledger_id;

  insert into public.promotion_grants (promotion_id, company_id, email_domain, expires_at, grant_ledger_id)
  values (v_promo.id, p_company_id, v_domain, v_expires, v_ledger_id)
  returning id into v_grant_id;

  perform public.log_audit(p_user_id, 'promo.granted', 'promotion_grants', v_grant_id, null,
    jsonb_build_object('promotion_id', v_promo.id, 'company_id', p_company_id,
                       'email_domain', v_domain, 'expires_at', v_expires));

  return 'granted';
end;
$$;

-- Spends the company's promo credit if, and only if, this order qualifies:
-- a standard UK-to-UK laptop return (drop-off; recipient and return
-- address both GB). Returns the grant id, or null to fall through to
-- purchased credits. Callers must already hold the company+kit advisory
-- lock. p_grace lets the Stripe webhook path honour a credit that was valid
-- when the customer started a cover checkout (Checkout Sessions last at
-- most 24 hours); every other path passes interval '0'.
create or replace function public.take_promo_credit(
  p_company_id uuid,
  p_kit_type_id text,
  p_service_type text,
  p_return_method text,
  p_employee_id uuid,
  p_employee_country text,
  p_return_address_id uuid,
  p_grace interval
)
returns uuid
language plpgsql
set search_path to 'public'
as $$
declare
  v_recipient_country text;
  v_return_country text;
  v_grant_id uuid;
begin
  if p_service_type <> 'return' or coalesce(p_return_method, 'drop_off') <> 'drop_off' then
    return null;
  end if;

  -- employees.country defaults to 'GB'; a manual recipient's country is
  -- already defaulted to 'GB' by the calling RPC.
  if p_employee_id is not null then
    select coalesce(country, 'GB') into v_recipient_country
    from public.employees where id = p_employee_id and company_id = p_company_id;
  else
    v_recipient_country := coalesce(p_employee_country, 'GB');
  end if;

  if p_return_address_id is not null then
    select country into v_return_country
    from public.addresses where id = p_return_address_id and company_id = p_company_id;
  else
    select country into v_return_country from public.companies where id = p_company_id;
  end if;

  if v_recipient_country is distinct from 'GB' or v_return_country is distinct from 'GB' then
    return null;
  end if;

  select g.id into v_grant_id
  from public.promotion_grants g
  join public.promotions p on p.id = g.promotion_id
  where g.company_id = p_company_id
    and p.kit_type_id = p_kit_type_id
    and g.status = 'issued'
    and g.expires_at > now() - p_grace
  order by g.expires_at
  limit 1
  for update of g;

  if v_grant_id is null then
    return null;
  end if;

  -- redeemed_order_id is set by finish_promo_redemption once the order row
  -- exists; the status/order-id CHECK is satisfied by setting both there.
  -- Until then the row stays 'issued' but locked by this transaction, so a
  -- concurrent redemption blocks on the row lock and then re-reads it.
  return v_grant_id;
end;
$$;

-- Marks the grant redeemed against the order just created, and raises the
-- duplicate-address flag if this order's recipient or return address
-- matches another company's redeemed promo order.
create or replace function public.finish_promo_redemption(p_grant_id uuid, p_order_id uuid)
returns void
language plpgsql
set search_path to 'public'
as $$
declare
  v_order public.orders%rowtype;
  v_line1 text;
  v_postcode text;
  v_recipient_key text;
  v_return_key text;
  v_matches jsonb;
begin
  select * into v_order from public.orders where id = p_order_id;

  if v_order.employee_id is not null then
    select address_line1, postcode into v_line1, v_postcode
    from public.employees where id = v_order.employee_id;
  else
    v_line1 := v_order.employee_address_line1;
    v_postcode := v_order.employee_postcode;
  end if;

  v_recipient_key := public.promo_address_key(v_line1, v_postcode);

  if v_order.return_address_id is not null then
    select public.promo_address_key(address_line1, postcode) into v_return_key
    from public.addresses where id = v_order.return_address_id;
  else
    select public.promo_address_key(address_line1, postcode) into v_return_key
    from public.companies where id = v_order.company_id;
  end if;

  select jsonb_agg(jsonb_build_object('grant_id', g.id, 'company_id', g.company_id, 'order_id', g.redeemed_order_id))
  into v_matches
  from public.promotion_grants g
  where g.company_id <> v_order.company_id
    and g.status = 'redeemed'
    and (
      (v_recipient_key is not null and v_recipient_key in (g.recipient_address_key, g.return_address_key))
      or (v_return_key is not null and v_return_key in (g.recipient_address_key, g.return_address_key))
    );

  update public.promotion_grants
  set status = 'redeemed',
      redeemed_order_id = p_order_id,
      redeemed_at = now(),
      recipient_address_key = v_recipient_key,
      return_address_key = v_return_key,
      address_flagged = v_matches is not null,
      address_flag_detail = v_matches
  where id = p_grant_id;
end;
$$;

revoke all on function public.purchased_credit_balance(uuid, text) from public, anon, authenticated;
revoke all on function public.promo_address_key(text, text) from public, anon, authenticated;
revoke all on function public.raise_insufficient_credit(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.grant_signup_promo(uuid, uuid) from public, anon, authenticated;
revoke all on function public.take_promo_credit(uuid, text, text, text, uuid, text, uuid, interval) from public, anon, authenticated;
revoke all on function public.finish_promo_redemption(uuid, uuid) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- Signup: create_company_and_admin() grants the promo at company setup.
-- The grant runs in its own sub-block -- any failure inside it is logged
-- and swallowed, so the promo can never block or roll back a signup.
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

  begin
    perform public.grant_signup_promo(new_company_id, auth.uid());
  exception when others then
    raise warning 'grant_signup_promo failed for company %: %', new_company_id, sqlerrm;
  end;

  return new_company_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- Redemption paths: create_order, create_internal_order,
-- create_credit_order_with_paid_cover. Each is its exact current definition
-- with four changes only: take the promo credit first when the order
-- qualifies, skip the volume-discount bundled cover on a promo redemption
-- (cover stays chargeable), read purchased balances via
-- purchased_credit_balance(), and tag the debit row with promotion_id.
-- Signatures unchanged, so existing grants carry over.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_order(p_kit_type_id text, p_service_type text, p_employee_id uuid DEFAULT NULL::uuid, p_return_address_id uuid DEFAULT NULL::uuid, p_device_reference text DEFAULT NULL::text, p_requested_send_date date DEFAULT NULL::date, p_leaver_last_day date DEFAULT NULL::date, p_bundle_id uuid DEFAULT NULL::uuid, p_order_reference text DEFAULT NULL::text, p_cover_tier_id text DEFAULT NULL::text, p_pay_with_credit boolean DEFAULT false, p_notify_employee boolean DEFAULT false, p_employee_name text DEFAULT NULL::text, p_employee_email text DEFAULT NULL::text, p_employee_address_line1 text DEFAULT NULL::text, p_employee_address_line2 text DEFAULT NULL::text, p_employee_city text DEFAULT NULL::text, p_employee_postcode text DEFAULT NULL::text, p_employee_country text DEFAULT NULL::text, p_return_method text DEFAULT 'drop_off'::text, p_collection_date date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company uuid := public.current_company();
  v_prefix text;
  v_price integer;
  v_active boolean;
  v_cover_price integer;
  v_cover_active boolean;
  v_effective_cover_tier_id text;
  v_enterprise boolean;
  v_ref text;
  v_order_id uuid;
  v_balance integer;
  v_ledger_id uuid;
  v_promo_grant_id uuid;
  v_promotion_id text;
  v_employee_country text;
  v_emp_email text;
  v_emp_address_line1 text;
  v_emp_city text;
  v_emp_postcode text;
begin
  if v_company is null then
    raise exception 'Must belong to a company';
  end if;

  if p_pay_with_credit and p_cover_tier_id is not null then
    raise exception 'Cannot pay with credit and add Enhanced Cover on the same order';
  end if;

  if p_return_method not in ('drop_off', 'collection') then
    raise exception 'Invalid return_method: %', p_return_method;
  end if;

  if p_return_method = 'collection' and p_collection_date is null then
    raise exception 'A collection date is required when return_method is collection';
  end if;

  if p_return_method = 'drop_off' and p_collection_date is not null then
    raise exception 'collection_date can only be set when return_method is collection';
  end if;

  if p_return_method = 'collection' and p_service_type <> 'return' then
    raise exception 'Collection can only be arranged for return orders';
  end if;

  if p_employee_id is not null and p_employee_name is not null then
    raise exception 'Provide either an existing employee or manual employee details, not both';
  end if;

  if p_employee_id is null and p_employee_name is null then
    raise exception 'An employee is required — pick an existing one or enter details manually';
  end if;

  if p_employee_id is not null then
    select email, address_line1, city, postcode
    into v_emp_email, v_emp_address_line1, v_emp_city, v_emp_postcode
    from public.employees
    where id = p_employee_id and company_id = v_company;

    if not found then
      raise exception 'Employee not found for this company';
    end if;

    perform public.check_recipient_completeness(
      v_emp_email, v_emp_address_line1, v_emp_city, v_emp_postcode, p_notify_employee, 'employee'
    );

    v_employee_country := null;
  else
    if length(trim(p_employee_name)) = 0 then
      raise exception 'Employee name cannot be blank';
    end if;

    perform public.check_recipient_completeness(
      p_employee_email, p_employee_address_line1, p_employee_city, p_employee_postcode, p_notify_employee, 'manual'
    );

    v_employee_country := coalesce(nullif(trim(p_employee_country), ''), 'GB');
  end if;

  if p_return_address_id is not null
     and not exists (select 1 from public.addresses where id = p_return_address_id and company_id = v_company) then
    raise exception 'Return address not found for this company';
  end if;

  if p_bundle_id is not null
     and not exists (select 1 from public.bundles where id = p_bundle_id and company_id = v_company) then
    raise exception 'Bundle not found for this company';
  end if;

  select reference_prefix, price_ex_vat_pence, active
  into v_prefix, v_price, v_active
  from public.kit_types
  where id = p_kit_type_id;

  if v_prefix is null then
    raise exception 'Unknown kit type: %', p_kit_type_id;
  end if;

  if not v_active then
    raise exception 'Kit type % is not currently orderable', p_kit_type_id;
  end if;

  -- Free first laptop return: under the same company+kit advisory lock
  -- every redemption takes, a qualifying order spends the promo credit
  -- first; anything else falls through to purchased credits.
  if p_pay_with_credit then
    perform pg_advisory_xact_lock(hashtextextended(v_company::text || ':' || p_kit_type_id, 0));

    v_promo_grant_id := public.take_promo_credit(
      v_company, p_kit_type_id, p_service_type, p_return_method, p_employee_id,
      v_employee_country, p_return_address_id, interval '0'
    );

    if v_promo_grant_id is not null then
      select promotion_id into v_promotion_id from public.promotion_grants where id = v_promo_grant_id;
    end if;
  end if;

  v_effective_cover_tier_id := p_cover_tier_id;

  if p_pay_with_credit and p_kit_type_id = 'laptop' and v_promo_grant_id is null then
    select volume_discounts_enabled into v_enterprise
    from public.companies where id = v_company;

    if coalesce(v_enterprise, false) then
      v_effective_cover_tier_id := 'up_to_500';
    end if;
  end if;

  if v_effective_cover_tier_id is not null then
    select price_ex_vat_pence, active into v_cover_price, v_cover_active
    from public.cover_tiers where id = v_effective_cover_tier_id;

    if v_cover_price is null then
      raise exception 'Unknown cover tier: %', v_effective_cover_tier_id;
    end if;

    if not v_cover_active then
      raise exception 'Cover tier % is not currently available', v_effective_cover_tier_id;
    end if;

    if p_pay_with_credit then
      v_cover_price := 0;
    end if;
  end if;

  if p_pay_with_credit and v_promo_grant_id is null then
    v_balance := public.purchased_credit_balance(v_company, p_kit_type_id);

    if v_balance < 1 then
      perform public.raise_insufficient_credit(v_company, p_kit_type_id, v_balance);
    end if;
  end if;

  v_ref := public.next_reference_number(v_prefix);

  if p_pay_with_credit then
    insert into public.credit_ledger (
      company_id, kit_type_id, transaction_type, direction, quantity,
      balance_after, actor_id, reason, promotion_id
    ) values (
      v_company, p_kit_type_id, 'redemption', 'debit', 1,
      case when v_promo_grant_id is null then v_balance - 1 else 0 end, auth.uid(),
      case when v_promo_grant_id is null then 'Redeemed for order ' || v_ref
           else 'Free first laptop return redeemed for order ' || v_ref end,
      v_promotion_id
    )
    returning id into v_ledger_id;
  end if;

  insert into public.orders (
    company_id, bundle_id, reference, order_reference, kit_type_id, service_type,
    source, created_by, employee_id, return_address_id, device_reference,
    price_ex_vat_pence, requested_send_date, leaver_last_day,
    cover_tier_id, cover_price_ex_vat_pence,
    payment_status, paid_with_credit, credit_transaction_id, notify_employee,
    employee_name, employee_email, employee_address_line1, employee_address_line2,
    employee_city, employee_postcode, employee_country,
    return_method, collection_date
  )
  values (
    v_company, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'customer', auth.uid(), p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day,
    v_effective_cover_tier_id, v_cover_price,
    case when p_pay_with_credit then 'paid' else 'pending' end, p_pay_with_credit, v_ledger_id, p_notify_employee,
    nullif(trim(coalesce(p_employee_name, '')), ''),
    nullif(trim(coalesce(p_employee_email, '')), ''),
    nullif(trim(coalesce(p_employee_address_line1, '')), ''),
    nullif(trim(coalesce(p_employee_address_line2, '')), ''),
    nullif(trim(coalesce(p_employee_city, '')), ''),
    nullif(trim(coalesce(p_employee_postcode, '')), ''),
    v_employee_country,
    p_return_method, p_collection_date
  )
  returning id into v_order_id;

  if p_pay_with_credit then
    update public.credit_ledger set order_id = v_order_id where id = v_ledger_id;
  end if;

  if v_promo_grant_id is not null then
    perform public.finish_promo_redemption(v_promo_grant_id, v_order_id);
  end if;

  perform public.log_audit(auth.uid(), 'order.create', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'cover_tier_id', v_effective_cover_tier_id, 'paid_with_credit', p_pay_with_credit,
                        'notify_employee', p_notify_employee, 'manual_employee', p_employee_id is null,
                        'return_method', p_return_method, 'collection_date', p_collection_date,
                        'promo_credit', v_promo_grant_id is not null));

  return v_order_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.create_internal_order(p_company_id uuid, p_actor_id uuid, p_kit_type_id text, p_service_type text, p_employee_id uuid DEFAULT NULL::uuid, p_return_address_id uuid DEFAULT NULL::uuid, p_device_reference text DEFAULT NULL::text, p_requested_send_date date DEFAULT NULL::date, p_leaver_last_day date DEFAULT NULL::date, p_bundle_id uuid DEFAULT NULL::uuid, p_order_reference text DEFAULT NULL::text, p_cover_tier_id text DEFAULT NULL::text, p_pay_with_credit boolean DEFAULT false, p_notify_employee boolean DEFAULT false, p_employee_name text DEFAULT NULL::text, p_employee_email text DEFAULT NULL::text, p_employee_address_line1 text DEFAULT NULL::text, p_employee_address_line2 text DEFAULT NULL::text, p_employee_city text DEFAULT NULL::text, p_employee_postcode text DEFAULT NULL::text, p_employee_country text DEFAULT NULL::text, p_return_method text DEFAULT 'drop_off'::text, p_collection_date date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prefix text;
  v_price integer;
  v_active boolean;
  v_cover_price integer;
  v_cover_active boolean;
  v_effective_cover_tier_id text;
  v_enterprise boolean;
  v_ref text;
  v_order_id uuid;
  v_balance integer;
  v_ledger_id uuid;
  v_promo_grant_id uuid;
  v_promotion_id text;
  v_employee_country text;
  v_emp_email text;
  v_emp_address_line1 text;
  v_emp_city text;
  v_emp_postcode text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'create_internal_order can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  if p_pay_with_credit and p_cover_tier_id is not null then
    raise exception 'Cannot pay with credit and add Enhanced Cover on the same order';
  end if;

  if p_return_method not in ('drop_off', 'collection') then
    raise exception 'Invalid return_method: %', p_return_method;
  end if;

  if p_return_method = 'collection' and p_collection_date is null then
    raise exception 'A collection date is required when return_method is collection';
  end if;

  if p_return_method = 'drop_off' and p_collection_date is not null then
    raise exception 'collection_date can only be set when return_method is collection';
  end if;

  if p_return_method = 'collection' and p_service_type <> 'return' then
    raise exception 'Collection can only be arranged for return orders';
  end if;

  if not exists (select 1 from public.companies where id = p_company_id) then
    raise exception 'Company % not found', p_company_id;
  end if;

  if p_employee_id is not null and p_employee_name is not null then
    raise exception 'Provide either an existing employee or manual employee details, not both';
  end if;

  if p_employee_id is null and p_employee_name is null then
    raise exception 'An employee is required — pick an existing one or enter details manually';
  end if;

  if p_employee_id is not null then
    select email, address_line1, city, postcode
    into v_emp_email, v_emp_address_line1, v_emp_city, v_emp_postcode
    from public.employees
    where id = p_employee_id and company_id = p_company_id;

    if not found then
      raise exception 'Employee not found for this company';
    end if;

    perform public.check_recipient_completeness(
      v_emp_email, v_emp_address_line1, v_emp_city, v_emp_postcode, p_notify_employee, 'employee'
    );

    v_employee_country := null;
  else
    if length(trim(p_employee_name)) = 0 then
      raise exception 'Employee name cannot be blank';
    end if;

    perform public.check_recipient_completeness(
      p_employee_email, p_employee_address_line1, p_employee_city, p_employee_postcode, p_notify_employee, 'manual'
    );

    v_employee_country := coalesce(nullif(trim(p_employee_country), ''), 'GB');
  end if;

  if p_return_address_id is not null
     and not exists (select 1 from public.addresses where id = p_return_address_id and company_id = p_company_id) then
    raise exception 'Return address not found for this company';
  end if;

  if p_bundle_id is not null
     and not exists (select 1 from public.bundles where id = p_bundle_id and company_id = p_company_id) then
    raise exception 'Bundle not found for this company';
  end if;

  select reference_prefix, price_ex_vat_pence, active
  into v_prefix, v_price, v_active
  from public.kit_types
  where id = p_kit_type_id;

  if v_prefix is null then
    raise exception 'Unknown kit type: %', p_kit_type_id;
  end if;

  if not v_active then
    raise exception 'Kit type % is not currently orderable', p_kit_type_id;
  end if;

  -- Free first laptop return: under the same company+kit advisory lock
  -- every redemption takes, a qualifying order spends the promo credit
  -- first; anything else falls through to purchased credits.
  if p_pay_with_credit then
    perform pg_advisory_xact_lock(hashtextextended(p_company_id::text || ':' || p_kit_type_id, 0));

    v_promo_grant_id := public.take_promo_credit(
      p_company_id, p_kit_type_id, p_service_type, p_return_method, p_employee_id,
      v_employee_country, p_return_address_id, interval '0'
    );

    if v_promo_grant_id is not null then
      select promotion_id into v_promotion_id from public.promotion_grants where id = v_promo_grant_id;
    end if;
  end if;

  v_effective_cover_tier_id := p_cover_tier_id;

  if p_pay_with_credit and p_kit_type_id = 'laptop' and v_promo_grant_id is null then
    select volume_discounts_enabled into v_enterprise
    from public.companies where id = p_company_id;

    if coalesce(v_enterprise, false) then
      v_effective_cover_tier_id := 'up_to_500';
    end if;
  end if;

  if v_effective_cover_tier_id is not null then
    select price_ex_vat_pence, active into v_cover_price, v_cover_active
    from public.cover_tiers where id = v_effective_cover_tier_id;

    if v_cover_price is null then
      raise exception 'Unknown cover tier: %', v_effective_cover_tier_id;
    end if;

    if not v_cover_active then
      raise exception 'Cover tier % is not currently available', v_effective_cover_tier_id;
    end if;

    if p_pay_with_credit then
      v_cover_price := 0;
    end if;
  end if;

  if p_pay_with_credit and v_promo_grant_id is null then
    v_balance := public.purchased_credit_balance(p_company_id, p_kit_type_id);

    if v_balance < 1 then
      perform public.raise_insufficient_credit(p_company_id, p_kit_type_id, v_balance);
    end if;
  end if;

  v_ref := public.next_reference_number(v_prefix);

  if p_pay_with_credit then
    insert into public.credit_ledger (
      company_id, kit_type_id, transaction_type, direction, quantity,
      balance_after, actor_id, reason, promotion_id
    ) values (
      p_company_id, p_kit_type_id, 'redemption', 'debit', 1,
      case when v_promo_grant_id is null then v_balance - 1 else 0 end, p_actor_id,
      case when v_promo_grant_id is null then 'Redeemed for order ' || v_ref
           else 'Free first laptop return redeemed for order ' || v_ref end,
      v_promotion_id
    )
    returning id into v_ledger_id;
  end if;

  insert into public.orders (
    company_id, bundle_id, reference, order_reference, kit_type_id, service_type,
    source, created_by, employee_id, return_address_id, device_reference,
    price_ex_vat_pence, requested_send_date, leaver_last_day,
    cover_tier_id, cover_price_ex_vat_pence,
    payment_status, paid_with_credit, credit_transaction_id, notify_employee,
    employee_name, employee_email, employee_address_line1, employee_address_line2,
    employee_city, employee_postcode, employee_country,
    return_method, collection_date
  )
  values (
    p_company_id, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'internal_staff', p_actor_id, p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day,
    v_effective_cover_tier_id, v_cover_price,
    case when p_pay_with_credit then 'paid' else 'pending' end, p_pay_with_credit, v_ledger_id, p_notify_employee,
    nullif(trim(coalesce(p_employee_name, '')), ''),
    nullif(trim(coalesce(p_employee_email, '')), ''),
    nullif(trim(coalesce(p_employee_address_line1, '')), ''),
    nullif(trim(coalesce(p_employee_address_line2, '')), ''),
    nullif(trim(coalesce(p_employee_city, '')), ''),
    nullif(trim(coalesce(p_employee_postcode, '')), ''),
    v_employee_country,
    p_return_method, p_collection_date
  )
  returning id into v_order_id;

  if p_pay_with_credit then
    update public.credit_ledger set order_id = v_order_id where id = v_ledger_id;
  end if;

  if v_promo_grant_id is not null then
    perform public.finish_promo_redemption(v_promo_grant_id, v_order_id);
  end if;

  perform public.log_audit(p_actor_id, 'order.create_internal', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'company_id', p_company_id, 'cover_tier_id', v_effective_cover_tier_id,
                        'paid_with_credit', p_pay_with_credit, 'notify_employee', p_notify_employee,
                        'manual_employee', p_employee_id is null,
                        'return_method', p_return_method, 'collection_date', p_collection_date,
                        'promo_credit', v_promo_grant_id is not null));

  return v_order_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.create_credit_order_with_paid_cover(p_event_id text, p_event_type text, p_checkout_session_id text, p_payment_intent_id text, p_company_id uuid, p_created_by uuid, p_kit_type_id text, p_service_type text, p_cover_tier_id text, p_cover_subtotal_ex_vat_pence integer, p_cover_vat_pence integer, p_cover_total_inc_vat_pence integer, p_employee_id uuid DEFAULT NULL::uuid, p_return_address_id uuid DEFAULT NULL::uuid, p_device_reference text DEFAULT NULL::text, p_requested_send_date date DEFAULT NULL::date, p_leaver_last_day date DEFAULT NULL::date, p_bundle_id uuid DEFAULT NULL::uuid, p_order_reference text DEFAULT NULL::text, p_notify_employee boolean DEFAULT false, p_employee_name text DEFAULT NULL::text, p_employee_email text DEFAULT NULL::text, p_employee_address_line1 text DEFAULT NULL::text, p_employee_address_line2 text DEFAULT NULL::text, p_employee_city text DEFAULT NULL::text, p_employee_postcode text DEFAULT NULL::text, p_employee_country text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_prefix text;
  v_price integer;
  v_kit_active boolean;
  v_cover_price integer;
  v_cover_active boolean;
  v_ref text;
  v_order_id uuid;
  v_balance integer;
  v_ledger_id uuid;
  v_promo_grant_id uuid;
  v_promotion_id text;
  v_invoice_id uuid;
  v_invoice_number integer;
  v_employee_country text;
  v_emp_email text;
  v_emp_address_line1 text;
  v_emp_city text;
  v_emp_postcode text;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Only the payment webhook can call create_credit_order_with_paid_cover';
  end if;

  if p_cover_tier_id is null then
    raise exception 'create_credit_order_with_paid_cover requires a cover tier';
  end if;

  insert into public.stripe_webhook_events (event_id, event_type)
  values (p_event_id, p_event_type)
  on conflict (event_id) do nothing;

  if not found then
    return null;
  end if;

  if p_employee_id is not null and p_employee_name is not null then
    raise exception 'Provide either an existing employee or manual employee details, not both';
  end if;

  if p_employee_id is null and p_employee_name is null then
    raise exception 'An employee is required — pick an existing one or enter details manually';
  end if;

  if p_employee_id is not null then
    select email, address_line1, city, postcode
    into v_emp_email, v_emp_address_line1, v_emp_city, v_emp_postcode
    from public.employees
    where id = p_employee_id and company_id = p_company_id;

    if not found then
      raise exception 'Employee not found for this company';
    end if;

    perform public.check_recipient_completeness(
      v_emp_email, v_emp_address_line1, v_emp_city, v_emp_postcode, p_notify_employee, 'employee'
    );

    v_employee_country := null;
  else
    if length(trim(p_employee_name)) = 0 then
      raise exception 'Employee name cannot be blank';
    end if;

    perform public.check_recipient_completeness(
      p_employee_email, p_employee_address_line1, p_employee_city, p_employee_postcode, p_notify_employee, 'manual'
    );

    v_employee_country := coalesce(nullif(trim(p_employee_country), ''), 'GB');
  end if;

  if p_return_address_id is not null
     and not exists (select 1 from public.addresses where id = p_return_address_id and company_id = p_company_id) then
    raise exception 'Return address not found for this company';
  end if;

  if p_bundle_id is not null
     and not exists (select 1 from public.bundles where id = p_bundle_id and company_id = p_company_id) then
    raise exception 'Bundle not found for this company';
  end if;

  select reference_prefix, price_ex_vat_pence, active
  into v_prefix, v_price, v_kit_active
  from public.kit_types
  where id = p_kit_type_id;

  if v_prefix is null then
    raise exception 'Unknown kit type: %', p_kit_type_id;
  end if;

  if not v_kit_active then
    raise exception 'Kit type % is not currently orderable', p_kit_type_id;
  end if;

  select price_ex_vat_pence, active into v_cover_price, v_cover_active
  from public.cover_tiers where id = p_cover_tier_id;

  if v_cover_price is null then
    raise exception 'Unknown cover tier: %', p_cover_tier_id;
  end if;

  if not v_cover_active then
    raise exception 'Cover tier % is not currently available', p_cover_tier_id;
  end if;

  if v_cover_price <= 0 then
    raise exception 'Cover tier % has no charge — nothing to pay separately for', p_cover_tier_id;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text || ':' || p_kit_type_id, 0));

  -- Free first laptop return: this path has no return_method param (the
  -- orders column defaults to drop_off). 24h grace: honour a promo credit
  -- that was valid when the customer started this cover checkout.
  v_promo_grant_id := public.take_promo_credit(
    p_company_id, p_kit_type_id, p_service_type, 'drop_off', p_employee_id,
    v_employee_country, p_return_address_id, interval '24 hours'
  );

  if v_promo_grant_id is not null then
    select promotion_id into v_promotion_id from public.promotion_grants where id = v_promo_grant_id;
  else
    v_balance := public.purchased_credit_balance(p_company_id, p_kit_type_id);

    if v_balance < 1 then
      perform public.raise_insufficient_credit(p_company_id, p_kit_type_id, v_balance);
    end if;
  end if;

  v_ref := public.next_reference_number(v_prefix);

  insert into public.credit_ledger (
    company_id, kit_type_id, transaction_type, direction, quantity,
    balance_after, actor_id, reason, promotion_id
  ) values (
    p_company_id, p_kit_type_id, 'redemption', 'debit', 1,
    case when v_promo_grant_id is null then v_balance - 1 else 0 end, p_created_by,
    case when v_promo_grant_id is null then 'Redeemed for order ' || v_ref || ' (cover paid separately)'
         else 'Free first laptop return redeemed for order ' || v_ref || ' (cover paid separately)' end,
    v_promotion_id
  )
  returning id into v_ledger_id;

  v_invoice_number := nextval('public.invoice_number_seq');

  insert into public.invoices (
    company_id, invoice_number, stripe_checkout_session_id, stripe_payment_intent_id,
    subtotal_ex_vat_pence, vat_pence, total_inc_vat_pence
  ) values (
    p_company_id, v_invoice_number, p_checkout_session_id, p_payment_intent_id,
    p_cover_subtotal_ex_vat_pence, p_cover_vat_pence, p_cover_total_inc_vat_pence
  )
  returning id into v_invoice_id;

  insert into public.orders (
    company_id, bundle_id, reference, order_reference, kit_type_id, service_type,
    source, created_by, employee_id, return_address_id, device_reference,
    price_ex_vat_pence, requested_send_date, leaver_last_day,
    cover_tier_id, cover_price_ex_vat_pence, cover_paid_separately,
    payment_status, paid_with_credit, credit_transaction_id, invoice_id, notify_employee,
    employee_name, employee_email, employee_address_line1, employee_address_line2,
    employee_city, employee_postcode, employee_country
  )
  values (
    p_company_id, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'customer', p_created_by, p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day,
    p_cover_tier_id, v_cover_price, true,
    'paid', true, v_ledger_id, v_invoice_id, p_notify_employee,
    nullif(trim(coalesce(p_employee_name, '')), ''),
    nullif(trim(coalesce(p_employee_email, '')), ''),
    nullif(trim(coalesce(p_employee_address_line1, '')), ''),
    nullif(trim(coalesce(p_employee_address_line2, '')), ''),
    nullif(trim(coalesce(p_employee_city, '')), ''),
    nullif(trim(coalesce(p_employee_postcode, '')), ''),
    v_employee_country
  )
  returning id into v_order_id;

  update public.credit_ledger set order_id = v_order_id where id = v_ledger_id;

  if v_promo_grant_id is not null then
    perform public.finish_promo_redemption(v_promo_grant_id, v_order_id);
  end if;

  perform public.log_audit(p_created_by, 'order.create', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'cover_tier_id', p_cover_tier_id, 'cover_paid_separately', true,
                        'paid_with_credit', true, 'promo_credit', v_promo_grant_id is not null,
                        'notify_employee', p_notify_employee,
                        'manual_employee', p_employee_id is null));

  return v_order_id;
end;
$function$;


-- record_credit_purchase: balance_after now reflects purchased credits only.
CREATE OR REPLACE FUNCTION public.record_credit_purchase(p_event_id text, p_event_type text, p_checkout_session_id text, p_payment_intent_id text, p_company_id uuid, p_kit_type_id text, p_quantity integer, p_subtotal_ex_vat_pence integer, p_vat_pence integer, p_total_inc_vat_pence integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_invoice_id uuid;
  v_invoice_number integer;
  v_balance integer;
begin
  insert into public.stripe_webhook_events (event_id, event_type)
  values (p_event_id, p_event_type)
  on conflict (event_id) do nothing;

  if not found then
    return null;
  end if;

  v_invoice_number := nextval('public.invoice_number_seq');

  insert into public.invoices (
    company_id, invoice_number, stripe_checkout_session_id, stripe_payment_intent_id,
    subtotal_ex_vat_pence, vat_pence, total_inc_vat_pence
  ) values (
    p_company_id, v_invoice_number, p_checkout_session_id, p_payment_intent_id,
    p_subtotal_ex_vat_pence, p_vat_pence, p_total_inc_vat_pence
  )
  returning id into v_invoice_id;

  v_balance := public.purchased_credit_balance(p_company_id, p_kit_type_id);

  insert into public.credit_ledger (
    company_id, kit_type_id, transaction_type, direction, quantity,
    balance_after, invoice_id, stripe_checkout_session_id, reason
  ) values (
    p_company_id, p_kit_type_id, 'purchase', 'credit', p_quantity,
    v_balance + p_quantity, v_invoice_id, p_checkout_session_id, 'Credit pack purchase'
  );

  return v_invoice_id;
end;
$function$;


-- ----------------------------------------------------------------------------
-- cancel_order: purchased credits restored exactly as before. A promo
-- credit is given back with its original expiry, or marked expired if that
-- has already passed.
-- ----------------------------------------------------------------------------

create or replace function public.cancel_order(p_order_id uuid, p_actor_id uuid, p_reason text default null::text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_order public.orders%rowtype;
  v_before jsonb;
  v_log_entry jsonb;
  v_balance integer;
  v_promotion_id text;
  v_grant public.promotion_grants%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'cancel_order can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if v_order.fulfilment_status <> 'awaiting_dispatch' then
    raise exception 'Order % cannot be cancelled (fulfilment_status: %) -- only orders still awaiting dispatch can be cancelled', p_order_id, v_order.fulfilment_status;
  end if;

  v_before := to_jsonb(v_order);

  v_log_entry := jsonb_build_object(
    'action', 'cancelled',
    'actor_id', p_actor_id,
    'at', now(),
    'detail', jsonb_build_object('reason', p_reason, 'was_paid', v_order.payment_status = 'paid')
  );

  update public.orders
  set fulfilment_status = 'cancelled',
      payment_status = 'cancelled',
      cancel_reason = p_reason,
      fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
  where id = p_order_id;

  if v_order.paid_with_credit then
    select promotion_id into v_promotion_id
    from public.credit_ledger where id = v_order.credit_transaction_id;

    if v_promotion_id is null then
      perform pg_advisory_xact_lock(hashtextextended(v_order.company_id::text || ':' || v_order.kit_type_id, 0));

      v_balance := public.purchased_credit_balance(v_order.company_id, v_order.kit_type_id);

      insert into public.credit_ledger (
        company_id, kit_type_id, transaction_type, direction, quantity,
        balance_after, order_id, actor_id, reason
      ) values (
        v_order.company_id, v_order.kit_type_id, 'adjustment', 'credit', 1,
        v_balance + 1, p_order_id, p_actor_id, 'Restored: order ' || v_order.reference || ' cancelled'
      );
    else
      select * into v_grant from public.promotion_grants
      where redeemed_order_id = p_order_id
      for update;

      if found then
        if v_grant.expires_at > now() then
          insert into public.credit_ledger (
            company_id, kit_type_id, transaction_type, direction, quantity,
            balance_after, order_id, actor_id, reason, promotion_id, expires_at
          ) values (
            v_order.company_id, v_order.kit_type_id, 'adjustment', 'credit', 1,
            1, p_order_id, p_actor_id, 'Free first laptop return restored: order ' || v_order.reference || ' cancelled',
            v_promotion_id, v_grant.expires_at
          );

          update public.promotion_grants
          set status = 'issued', redeemed_order_id = null, redeemed_at = null,
              recipient_address_key = null, return_address_key = null,
              address_flagged = false, address_flag_detail = null
          where id = v_grant.id;
        else
          -- Already past its expiry: nothing to give back. The grant credit
          -- and the redemption debit already net to zero in the ledger.
          update public.promotion_grants
          set status = 'expired', expired_at = now(), redeemed_order_id = null, redeemed_at = null
          where id = v_grant.id;
        end if;
      end if;
    end if;
  end if;

  perform public.log_audit(
    p_actor_id, 'order.cancel', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$function$;

-- ----------------------------------------------------------------------------
-- Expiry: daily pg_cron job writes an offsetting debit (never mutates the
-- original grant row, consistent with the append-only ledger) and marks
-- the grant expired. Redemption already refuses an expired credit on its
-- own, so the job only tidies the books -- a late run is harmless.
-- ----------------------------------------------------------------------------

create or replace function public.expire_promo_credits()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_grant record;
  v_count integer := 0;
begin
  for v_grant in
    select g.id, g.company_id, g.promotion_id, p.kit_type_id
    from public.promotion_grants g
    join public.promotions p on p.id = g.promotion_id
    where g.status = 'issued' and g.expires_at <= now()
    for update of g skip locked
  loop
    insert into public.credit_ledger (
      company_id, kit_type_id, transaction_type, direction, quantity,
      balance_after, reason, promotion_id
    ) values (
      v_grant.company_id, v_grant.kit_type_id, 'adjustment', 'debit', 1,
      0, 'Free first laptop return expired unused', v_grant.promotion_id
    );

    update public.promotion_grants
    set status = 'expired', expired_at = now()
    where id = v_grant.id;

    perform public.log_audit(null, 'promo.expired', 'promotion_grants', v_grant.id, null,
      jsonb_build_object('company_id', v_grant.company_id, 'promotion_id', v_grant.promotion_id));

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.expire_promo_credits() from public;
revoke execute on function public.expire_promo_credits() from anon, authenticated;
grant execute on function public.expire_promo_credits() to service_role;

select cron.schedule(
  'promo-credit-expiry-daily',
  '15 2 * * *',
  $$select public.expire_promo_credits();$$
);

-- ----------------------------------------------------------------------------
-- Retool: the admin on/off switch. Same hardened staff-RPC pattern as
-- cancel_order / set_order_status.
-- ----------------------------------------------------------------------------

create or replace function public.set_promotion_enabled(p_promotion_id text, p_actor_id uuid, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_before jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'set_promotion_enabled can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  select to_jsonb(p) into v_before from public.promotions p where id = p_promotion_id for update;
  if v_before is null then
    raise exception 'Promotion % not found', p_promotion_id;
  end if;

  update public.promotions
  set enabled = p_enabled,
      first_enabled_at = coalesce(first_enabled_at, case when p_enabled then now() end),
      updated_at = now()
  where id = p_promotion_id;

  perform public.log_audit(p_actor_id, 'promo.set_enabled', 'promotions', null, v_before,
    (select to_jsonb(p) from public.promotions p where id = p_promotion_id));
end;
$$;

revoke all on function public.set_promotion_enabled(text, uuid, boolean) from public;
revoke execute on function public.set_promotion_enabled(text, uuid, boolean) from anon, authenticated;
grant execute on function public.set_promotion_enabled(text, uuid, boolean) to service_role;

-- ----------------------------------------------------------------------------
-- Reporting (Retool reads these over its own privileged connection).
-- promotion_grant_report: one row per company that got the credit, with
-- what it went on to buy. promotion_summary: the headline numbers.
-- ----------------------------------------------------------------------------

create view public.promotion_grant_report
with (security_invoker = true) as
select
  g.promotion_id,
  g.company_id,
  c.name as company_name,
  g.email_domain,
  g.status,
  g.granted_at,
  g.expires_at,
  g.redeemed_at,
  o.reference as redeemed_order_reference,
  g.expired_at,
  g.address_flagged,
  g.address_flag_detail,
  coalesce((
    select sum(l.quantity) from public.credit_ledger l
    where l.company_id = g.company_id and l.transaction_type = 'purchase' and l.created_at >= g.granted_at
  ), 0)::integer as credits_purchased_after,
  coalesce((
    select sum(i.total_inc_vat_pence) from public.invoices i
    where i.company_id = g.company_id and i.created_at >= g.granted_at and i.voided_at is null
  ), 0)::integer as revenue_pence_after,
  exists (
    select 1 from public.invoices i
    where i.company_id = g.company_id and i.created_at >= g.granted_at and i.voided_at is null
  ) as became_paying_customer
from public.promotion_grants g
join public.companies c on c.id = g.company_id
left join public.orders o on o.id = g.redeemed_order_id;

create view public.promotion_summary
with (security_invoker = true) as
select
  p.id as promotion_id,
  p.enabled,
  p.max_grants,
  p.first_enabled_at,
  (select count(*) from public.companies c where p.first_enabled_at is not null and c.created_at >= p.first_enabled_at)::integer as signups_since_launch,
  (select count(*) from public.promotion_grants g where g.promotion_id = p.id)::integer as credits_issued,
  (select count(*) from public.audit_log a where a.action = 'promo.not_granted' and a.after ->> 'promotion_id' = p.id)::integer as signups_not_qualifying,
  (select count(*) from public.promotion_grants g where g.promotion_id = p.id and g.status = 'issued')::integer as credits_unused,
  (select count(*) from public.promotion_grants g where g.promotion_id = p.id and g.status = 'redeemed')::integer as credits_redeemed,
  (select count(*) from public.promotion_grants g where g.promotion_id = p.id and g.status = 'expired')::integer as credits_expired,
  (select count(*) from public.promotion_grants g where g.promotion_id = p.id and g.address_flagged)::integer as redemptions_flagged,
  (select count(*) from public.promotion_grant_report r where r.promotion_id = p.id and r.became_paying_customer)::integer as companies_paying_after,
  (select coalesce(sum(r.revenue_pence_after), 0) from public.promotion_grant_report r where r.promotion_id = p.id)::integer as revenue_pence_after
from public.promotions p;

revoke all on public.promotion_grant_report from public, anon, authenticated;
revoke all on public.promotion_summary from public, anon, authenticated;
grant select on public.promotion_grant_report to service_role;
grant select on public.promotion_summary to service_role;
