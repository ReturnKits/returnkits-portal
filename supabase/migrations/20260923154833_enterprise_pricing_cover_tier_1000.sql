-- Backfilled from the hosted project (applied there directly via apply_migration)
-- so a local `db reset` reproduces hosted.
-- Change the free cover tier auto-attached to Enterprise-priced Laptop credit
-- redemptions from Enhanced Cover up to £2,000 to Enhanced Cover up to £1,000.
-- User-confirmed real behaviour change (not just portal copy) — 20260923.
--
-- Both create_order and create_internal_order hardcode this tier id directly
-- (enterprise_pricing_tiers.includes_cover_tier_id exists but is never read by
-- either function — a pre-existing, undocumented dead column, left as-is here;
-- only the hardcoded literal actually drives behaviour). Signatures unchanged.

create or replace function public.create_order(
  p_kit_type_id text,
  p_service_type text,
  p_employee_id uuid default null::uuid,
  p_return_address_id uuid default null::uuid,
  p_device_reference text default null::text,
  p_requested_send_date date default null::date,
  p_leaver_last_day date default null::date,
  p_bundle_id uuid default null::uuid,
  p_order_reference text default null::text,
  p_cover_tier_id text default null::text,
  p_pay_with_credit boolean default false,
  p_notify_employee boolean default false,
  p_employee_name text default null::text,
  p_employee_email text default null::text,
  p_employee_address_line1 text default null::text,
  p_employee_address_line2 text default null::text,
  p_employee_city text default null::text,
  p_employee_postcode text default null::text,
  p_employee_country text default null::text,
  p_return_method text default 'drop_off'::text,
  p_collection_date date default null::date
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

  v_effective_cover_tier_id := p_cover_tier_id;

  if p_pay_with_credit and p_kit_type_id = 'laptop' then
    select enterprise_pricing_enabled into v_enterprise
    from public.companies where id = v_company;

    if coalesce(v_enterprise, false) then
      v_effective_cover_tier_id := 'up_to_1000';
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

  perform public.log_audit(auth.uid(), 'order.create', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'cover_tier_id', v_effective_cover_tier_id, 'paid_with_credit', p_pay_with_credit,
                        'notify_employee', p_notify_employee, 'manual_employee', p_employee_id is null,
                        'return_method', p_return_method, 'collection_date', p_collection_date));

  return v_order_id;
end;
$function$;

create or replace function public.create_internal_order(
  p_company_id uuid,
  p_actor_id uuid,
  p_kit_type_id text,
  p_service_type text,
  p_employee_id uuid default null::uuid,
  p_return_address_id uuid default null::uuid,
  p_device_reference text default null::text,
  p_requested_send_date date default null::date,
  p_leaver_last_day date default null::date,
  p_bundle_id uuid default null::uuid,
  p_order_reference text default null::text,
  p_cover_tier_id text default null::text,
  p_pay_with_credit boolean default false,
  p_notify_employee boolean default false,
  p_employee_name text default null::text,
  p_employee_email text default null::text,
  p_employee_address_line1 text default null::text,
  p_employee_address_line2 text default null::text,
  p_employee_city text default null::text,
  p_employee_postcode text default null::text,
  p_employee_country text default null::text,
  p_return_method text default 'drop_off'::text,
  p_collection_date date default null::date
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

  v_effective_cover_tier_id := p_cover_tier_id;

  if p_pay_with_credit and p_kit_type_id = 'laptop' then
    select enterprise_pricing_enabled into v_enterprise
    from public.companies where id = p_company_id;

    if coalesce(v_enterprise, false) then
      v_effective_cover_tier_id := 'up_to_1000';
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

  perform public.log_audit(p_actor_id, 'order.create_internal', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'company_id', p_company_id, 'cover_tier_id', v_effective_cover_tier_id,
                        'paid_with_credit', p_pay_with_credit, 'notify_employee', p_notify_employee,
                        'manual_employee', p_employee_id is null,
                        'return_method', p_return_method, 'collection_date', p_collection_date));

  return v_order_id;
end;
$function$;

-- Re-apply confirmed live grants explicitly (CREATE OR REPLACE FUNCTION does not
-- reliably carry a prior grant fix forward — hard-learned discipline in this project).
revoke all on function public.create_order(
  text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean,
  text, text, text, text, text, text, text, text, date
) from public, anon, authenticated;
grant execute on function public.create_order(
  text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean,
  text, text, text, text, text, text, text, text, date
) to authenticated;

revoke all on function public.create_internal_order(
  uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean,
  text, text, text, text, text, text, text, text, date
) from public, anon, authenticated;
grant execute on function public.create_internal_order(
  uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean,
  text, text, text, text, text, text, text, text, date
) to service_role;

-- Data consistency: enterprise_pricing_tiers.includes_cover_tier_id isn't currently
-- read by either RPC above (both hardcode the literal instead), but keep it accurate.
update public.enterprise_pricing_tiers
set includes_cover_tier_id = 'up_to_1000'
where includes_cover_tier_id = 'up_to_2000';
