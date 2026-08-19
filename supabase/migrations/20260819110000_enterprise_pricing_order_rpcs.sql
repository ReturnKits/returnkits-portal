-- supabase/migrations/20260819110000_enterprise_pricing_order_rpcs.sql
--
-- Hand-written per CLAUDE.md. Extends create_order/create_internal_order
-- (CREATE OR REPLACE, identical signatures -- no new params, so this does
-- NOT reintroduce the overload-duplication bug fixed 20260813) so that a
-- credit-paid Laptop order for an enterprise_pricing_enabled company
-- automatically attaches Enhanced Cover (up to £2,000) at zero extra
-- charge, per the enterprise_pricing schema added in the migration just
-- before this one.
--
-- The existing guard "cannot pay with credit and add Enhanced Cover on the
-- same order" is left untouched and still fires on any EXPLICIT
-- p_cover_tier_id passed alongside p_pay_with_credit=true -- callers still
-- cannot request a separately-charged cover on a credit order. The
-- auto-attach path below is entirely separate: it only ever fires when the
-- caller passed NO cover tier at all, and only sets a bundled, zero-price
-- one, which is exactly what orders_credit_excludes_cover's relaxed CHECK
-- now permits.

create or replace function public.create_order(
  p_kit_type_id text,
  p_service_type text,
  p_employee_id uuid default null,
  p_return_address_id uuid default null,
  p_device_reference text default null,
  p_requested_send_date date default null,
  p_leaver_last_day date default null,
  p_bundle_id uuid default null,
  p_order_reference text default null,
  p_cover_tier_id text default null,
  p_pay_with_credit boolean default false,
  p_notify_employee boolean default false,
  p_employee_name text default null,
  p_employee_email text default null,
  p_employee_address_line1 text default null,
  p_employee_address_line2 text default null,
  p_employee_city text default null,
  p_employee_postcode text default null,
  p_employee_country text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
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
  v_employee_country text;
begin
  if v_company is null then
    raise exception 'Must belong to a company';
  end if;

  if p_pay_with_credit and p_cover_tier_id is not null then
    raise exception 'Cannot pay with credit and add Enhanced Cover on the same order';
  end if;

  if p_employee_id is not null and p_employee_name is not null then
    raise exception 'Provide either an existing employee or manual employee details, not both';
  end if;

  if p_employee_id is null and p_employee_name is null then
    raise exception 'An employee is required — pick an existing one or enter details manually';
  end if;

  if p_employee_id is not null then
    if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
      raise exception 'Employee not found for this company';
    end if;
    v_employee_country := null;
  else
    if length(trim(p_employee_name)) = 0 then
      raise exception 'Employee name cannot be blank';
    end if;
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

  -- Enterprise pricing: a credit-paid Laptop order for a company with the
  -- switch on auto-attaches the bundled Enhanced Cover-2000 tier, at zero
  -- extra charge (already paid for as part of the tiered credit price).
  -- Only fires when the caller passed no explicit cover tier -- the guard
  -- above already rejects an explicit one alongside p_pay_with_credit.
  v_effective_cover_tier_id := p_cover_tier_id;

  if p_pay_with_credit and p_kit_type_id = 'laptop' then
    select enterprise_pricing_enabled into v_enterprise
    from public.companies where id = v_company;

    if coalesce(v_enterprise, false) then
      v_effective_cover_tier_id := 'up_to_2000';
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
      -- Bundled into the tiered credit price, never a separate charge --
      -- see orders_credit_excludes_cover's relaxed CHECK.
      v_cover_price := 0;
    end if;
  end if;

  if p_pay_with_credit then
    perform pg_advisory_xact_lock(hashtextextended(v_company::text || ':' || p_kit_type_id, 0));

    select coalesce(sum(case when direction = 'credit' then quantity else -quantity end), 0)
    into v_balance
    from public.credit_ledger
    where company_id = v_company and kit_type_id = p_kit_type_id;

    if v_balance < 1 then
      raise exception 'Insufficient % credit balance (have %, need 1)', p_kit_type_id, v_balance;
    end if;
  end if;

  v_ref := public.next_reference_number(v_prefix);

  if p_pay_with_credit then
    insert into public.credit_ledger (
      company_id, kit_type_id, transaction_type, direction, quantity,
      balance_after, actor_id, reason
    ) values (
      v_company, p_kit_type_id, 'redemption', 'debit', 1,
      v_balance - 1, auth.uid(), 'Redeemed for order ' || v_ref
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
    employee_city, employee_postcode, employee_country
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
    v_employee_country
  )
  returning id into v_order_id;

  if p_pay_with_credit then
    update public.credit_ledger set order_id = v_order_id where id = v_ledger_id;
  end if;

  perform public.log_audit(auth.uid(), 'order.create', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'cover_tier_id', v_effective_cover_tier_id, 'paid_with_credit', p_pay_with_credit,
                        'notify_employee', p_notify_employee, 'manual_employee', p_employee_id is null));

  return v_order_id;
end;
$function$;

create or replace function public.create_internal_order(
  p_company_id uuid,
  p_actor_id uuid,
  p_kit_type_id text,
  p_service_type text,
  p_employee_id uuid default null,
  p_return_address_id uuid default null,
  p_device_reference text default null,
  p_requested_send_date date default null,
  p_leaver_last_day date default null,
  p_bundle_id uuid default null,
  p_order_reference text default null,
  p_cover_tier_id text default null,
  p_pay_with_credit boolean default false,
  p_notify_employee boolean default false,
  p_employee_name text default null,
  p_employee_email text default null,
  p_employee_address_line1 text default null,
  p_employee_address_line2 text default null,
  p_employee_city text default null,
  p_employee_postcode text default null,
  p_employee_country text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
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
  v_employee_country text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'create_internal_order can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  if p_pay_with_credit and p_cover_tier_id is not null then
    raise exception 'Cannot pay with credit and add Enhanced Cover on the same order';
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
    if not exists (select 1 from public.employees where id = p_employee_id and company_id = p_company_id) then
      raise exception 'Employee not found for this company';
    end if;
    v_employee_country := null;
  else
    if length(trim(p_employee_name)) = 0 then
      raise exception 'Employee name cannot be blank';
    end if;
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

  -- Enterprise pricing auto-attach, same rule as create_order.
  v_effective_cover_tier_id := p_cover_tier_id;

  if p_pay_with_credit and p_kit_type_id = 'laptop' then
    select enterprise_pricing_enabled into v_enterprise
    from public.companies where id = p_company_id;

    if coalesce(v_enterprise, false) then
      v_effective_cover_tier_id := 'up_to_2000';
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

  if p_pay_with_credit then
    perform pg_advisory_xact_lock(hashtextextended(p_company_id::text || ':' || p_kit_type_id, 0));

    select coalesce(sum(case when direction = 'credit' then quantity else -quantity end), 0)
    into v_balance
    from public.credit_ledger
    where company_id = p_company_id and kit_type_id = p_kit_type_id;

    if v_balance < 1 then
      raise exception 'Insufficient % credit balance (have %, need 1)', p_kit_type_id, v_balance;
    end if;
  end if;

  v_ref := public.next_reference_number(v_prefix);

  if p_pay_with_credit then
    insert into public.credit_ledger (
      company_id, kit_type_id, transaction_type, direction, quantity,
      balance_after, actor_id, reason
    ) values (
      p_company_id, p_kit_type_id, 'redemption', 'debit', 1,
      v_balance - 1, p_actor_id, 'Redeemed for order ' || v_ref
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
    employee_city, employee_postcode, employee_country
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
    v_employee_country
  )
  returning id into v_order_id;

  if p_pay_with_credit then
    update public.credit_ledger set order_id = v_order_id where id = v_ledger_id;
  end if;

  perform public.log_audit(p_actor_id, 'order.create_internal', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'company_id', p_company_id, 'cover_tier_id', v_effective_cover_tier_id,
                        'paid_with_credit', p_pay_with_credit, 'notify_employee', p_notify_employee,
                        'manual_employee', p_employee_id is null));

  return v_order_id;
end;
$function$;

-- Both functions' EXECUTE grants: create_order keeps 'authenticated' (a
-- signed-in company user calls it directly), create_internal_order is
-- service_role-only in its own body already (see the guard above) but per
-- the 20260816 grant-leak lesson, explicitly revoke from anon/authenticated
-- on every migration that replaces it, since CREATE OR REPLACE does not
-- carry a prior migration's revoke forward.
--
-- Found live while applying this migration, worth noting for any future
-- fix in this family: revoking from anon/authenticated ALONE is not
-- sufficient. A fresh check against information_schema.routine_privileges
-- immediately after this CREATE OR REPLACE showed create_internal_order
-- still granted to the "PUBLIC" pseudo-role -- and in Postgres every role,
-- anon/authenticated included, is implicitly a member of PUBLIC, so a
-- PUBLIC grant is exploitable by anon/authenticated regardless of an
-- explicit per-role revoke naming them individually. None of this
-- codebase's prior grant-lockdown migrations (20260813170000, 20260816180000)
-- ever revoked from PUBLIC specifically, only from anon/authenticated -- so
-- this same gap likely still exists on some of those other functions too
-- (spot-checked live: trigger_scheduled_tracking_poll still shows PUBLIC).
-- Out of scope to fix every prior function as part of this migration, but
-- flagged here and in CLAUDE.md as a real, not-yet-fully-closed follow-up.
revoke execute on function public.create_internal_order(
  uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean,
  text, text, text, text, text, text, text
) from public, anon, authenticated;
