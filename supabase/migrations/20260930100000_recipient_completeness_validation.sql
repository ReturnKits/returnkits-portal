-- Enforce recipient completeness (address line 1, city, postcode; email when
-- notify_employee is set) at order-creation time, for both the manual-entry
-- path and the existing-employee path. Backend mirror of the New Order form
-- validation — see orders.new.tsx for the matching frontend checks.
--
-- Scope deliberately limited to address + notification validation, matching
-- the recipient/employee columns that already exist on both `employees` and
-- `orders` (full_name, email, address_line1, address_line2, city, postcode,
-- country). Nothing else about order creation changes.

create or replace function public.check_recipient_completeness(
  p_email text,
  p_address_line1 text,
  p_city text,
  p_postcode text,
  p_notify_employee boolean,
  p_source text -- 'employee' (existing directory record) or 'manual' (one-off entry)
) returns void
language plpgsql
as $$
declare
  v_missing text[] := array[]::text[];
begin
  if p_address_line1 is null or length(trim(p_address_line1)) = 0 then
    v_missing := array_append(v_missing, 'address line 1');
  end if;

  if p_city is null or length(trim(p_city)) = 0 then
    v_missing := array_append(v_missing, 'city');
  end if;

  if p_postcode is null or length(trim(p_postcode)) = 0 then
    v_missing := array_append(v_missing, 'postcode');
  end if;

  if p_notify_employee then
    if p_email is null or length(trim(p_email)) = 0 then
      v_missing := array_append(v_missing, 'email (required to notify the employee)');
    elsif trim(p_email) !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      raise exception 'The email address on file is not valid — correct it before enabling employee notifications';
    end if;
  end if;

  if array_length(v_missing, 1) > 0 then
    if p_source = 'employee' then
      raise exception 'This employee''s saved details are incomplete — missing: %. Update their record in the employee directory, or enter the recipient''s details manually for this order.',
        array_to_string(v_missing, ', ');
    else
      raise exception 'Recipient details are incomplete — missing: %.',
        array_to_string(v_missing, ', ');
    end if;
  end if;
end;
$$;

-- create_order: customer-facing RPC (Lovable New Order form)
create or replace function public.create_order(p_kit_type_id text, p_service_type text, p_employee_id uuid DEFAULT NULL::uuid, p_return_address_id uuid DEFAULT NULL::uuid, p_device_reference text DEFAULT NULL::text, p_requested_send_date date DEFAULT NULL::date, p_leaver_last_day date DEFAULT NULL::date, p_bundle_id uuid DEFAULT NULL::uuid, p_order_reference text DEFAULT NULL::text, p_cover_tier_id text DEFAULT NULL::text, p_pay_with_credit boolean DEFAULT false, p_notify_employee boolean DEFAULT false, p_employee_name text DEFAULT NULL::text, p_employee_email text DEFAULT NULL::text, p_employee_address_line1 text DEFAULT NULL::text, p_employee_address_line2 text DEFAULT NULL::text, p_employee_city text DEFAULT NULL::text, p_employee_postcode text DEFAULT NULL::text, p_employee_country text DEFAULT NULL::text, p_return_method text DEFAULT 'drop_off'::text, p_collection_date date DEFAULT NULL::date)
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

  v_effective_cover_tier_id := p_cover_tier_id;

  if p_pay_with_credit and p_kit_type_id = 'laptop' then
    select enterprise_pricing_enabled into v_enterprise
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

revoke all on function public.create_order(text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean, text, text, text, text, text, text, text, text, date) from public, anon, authenticated;
grant execute on function public.create_order(text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean, text, text, text, text, text, text, text, text, date) to authenticated, postgres, service_role;

-- create_internal_order: Retool-facing RPC (service_role only)
create or replace function public.create_internal_order(p_company_id uuid, p_actor_id uuid, p_kit_type_id text, p_service_type text, p_employee_id uuid DEFAULT NULL::uuid, p_return_address_id uuid DEFAULT NULL::uuid, p_device_reference text DEFAULT NULL::text, p_requested_send_date date DEFAULT NULL::date, p_leaver_last_day date DEFAULT NULL::date, p_bundle_id uuid DEFAULT NULL::uuid, p_order_reference text DEFAULT NULL::text, p_cover_tier_id text DEFAULT NULL::text, p_pay_with_credit boolean DEFAULT false, p_notify_employee boolean DEFAULT false, p_employee_name text DEFAULT NULL::text, p_employee_email text DEFAULT NULL::text, p_employee_address_line1 text DEFAULT NULL::text, p_employee_address_line2 text DEFAULT NULL::text, p_employee_city text DEFAULT NULL::text, p_employee_postcode text DEFAULT NULL::text, p_employee_country text DEFAULT NULL::text, p_return_method text DEFAULT 'drop_off'::text, p_collection_date date DEFAULT NULL::date)
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

  v_effective_cover_tier_id := p_cover_tier_id;

  if p_pay_with_credit and p_kit_type_id = 'laptop' then
    select enterprise_pricing_enabled into v_enterprise
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

revoke all on function public.create_internal_order(uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean, text, text, text, text, text, text, text, text, date) from public, anon, authenticated;
grant execute on function public.create_internal_order(uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text, text, boolean, boolean, text, text, text, text, text, text, text, text, date) to postgres, service_role;

-- create_credit_order_with_paid_cover: webhook-only RPC, fires after Stripe has
-- already captured payment for the separately-charged cover. Same completeness
-- rule applied for consistency; the New Order form's own frontend validation
-- (and create-credit-order-cover-checkout-session's own recipient lookup) should
-- catch incompleteness before Stripe is ever charged, so hitting this exception
-- in practice should be rare — same accepted-edge-case posture already documented
-- for this function's insufficient-balance case (no automated refund exists).
create or replace function public.create_credit_order_with_paid_cover(p_event_id text, p_event_type text, p_checkout_session_id text, p_payment_intent_id text, p_company_id uuid, p_created_by uuid, p_kit_type_id text, p_service_type text, p_cover_tier_id text, p_cover_subtotal_ex_vat_pence integer, p_cover_vat_pence integer, p_cover_total_inc_vat_pence integer, p_employee_id uuid DEFAULT NULL::uuid, p_return_address_id uuid DEFAULT NULL::uuid, p_device_reference text DEFAULT NULL::text, p_requested_send_date date DEFAULT NULL::date, p_leaver_last_day date DEFAULT NULL::date, p_bundle_id uuid DEFAULT NULL::uuid, p_order_reference text DEFAULT NULL::text, p_notify_employee boolean DEFAULT false, p_employee_name text DEFAULT NULL::text, p_employee_email text DEFAULT NULL::text, p_employee_address_line1 text DEFAULT NULL::text, p_employee_address_line2 text DEFAULT NULL::text, p_employee_city text DEFAULT NULL::text, p_employee_postcode text DEFAULT NULL::text, p_employee_country text DEFAULT NULL::text)
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

  select coalesce(sum(case when direction = 'credit' then quantity else -quantity end), 0)
  into v_balance
  from public.credit_ledger
  where company_id = p_company_id and kit_type_id = p_kit_type_id;

  if v_balance < 1 then
    raise exception 'Insufficient % credit balance (have %, need 1)', p_kit_type_id, v_balance;
  end if;

  v_ref := public.next_reference_number(v_prefix);

  insert into public.credit_ledger (
    company_id, kit_type_id, transaction_type, direction, quantity,
    balance_after, actor_id, reason
  ) values (
    p_company_id, p_kit_type_id, 'redemption', 'debit', 1,
    v_balance - 1, p_created_by, 'Redeemed for order ' || v_ref || ' (cover paid separately)'
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

  perform public.log_audit(p_created_by, 'order.create', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'cover_tier_id', p_cover_tier_id, 'cover_paid_separately', true,
                        'paid_with_credit', true, 'notify_employee', p_notify_employee,
                        'manual_employee', p_employee_id is null));

  return v_order_id;
end;
$function$;

revoke all on function public.create_credit_order_with_paid_cover(text, text, text, text, uuid, uuid, text, text, text, integer, integer, integer, uuid, uuid, text, date, date, uuid, text, boolean, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.create_credit_order_with_paid_cover(text, text, text, text, uuid, uuid, text, text, text, integer, integer, integer, uuid, uuid, text, date, date, uuid, text, boolean, text, text, text, text, text, text, text) to postgres, service_role;
