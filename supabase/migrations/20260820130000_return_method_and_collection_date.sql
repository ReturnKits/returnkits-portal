-- supabase/migrations/20260820130000_return_method_and_collection_date.sql
--
-- Adds a real "how is the device coming back to us" choice to return
-- orders: drop_off (default, unchanged behaviour) or collection (a courier
-- collects from the employee on a specific date). Direct follow-on from a
-- code review the user asked for: the return-order dispatched email's
-- "Sending the device back" instructions were hardcoded to drop-off
-- language ("Drop it off with [courier]") with no way to say "a courier
-- will collect it on [date]" when a collection has actually been arranged
-- -- see the accompanying send-order-email rewrite for the wording fix this
-- schema change unblocks.
--
-- Scoped with the user directly: entered by the CUSTOMER at order creation
-- (Lovable New Order form, not Retool) -- confirmed despite collections
-- normally being arranged with the courier closer to dispatch time, because
-- the user was explicit that "the portal" (this project's term for the
-- Lovable app) is where this belongs. Either/or, not both: an order is
-- either drop_off or collection, never a "suggested date, fallback to
-- drop-off" hybrid -- confirmed with the user ("give option for collection
-- or drop off").

alter table public.orders
  add column return_method text not null default 'drop_off';

alter table public.orders
  add constraint orders_return_method_check
  check (return_method in ('drop_off', 'collection'));

alter table public.orders
  add column collection_date date;

-- Same "declared enums must be enforced with CHECK" discipline this whole
-- project runs on (Base44 audit: 51 of 54 orders held a status the schema
-- prohibited, because nothing enforced it) -- collection_date is set if and
-- only if return_method = 'collection'. Never a stray date on a drop_off
-- order, never a collection order with no date.
alter table public.orders
  add constraint orders_collection_date_consistent
  check ((return_method = 'collection') = (collection_date is not null));

-- A ship_to_new_employee order has no "sending it back" leg to collect --
-- collection only ever makes sense on a return order. drop_off is the
-- harmless default for every other service type, so this only restricts
-- the 'collection' value, not the column's existence.
alter table public.orders
  add constraint orders_collection_only_for_return
  check (return_method = 'drop_off' or service_type = 'return');

-- ---------------------------------------------------------------------
-- create_order / create_internal_order: add p_return_method / p_collection_date
--
-- CREATE OR REPLACE FUNCTION does NOT treat "same name, new trailing
-- optional params" as a replace of the existing function -- Postgres keys
-- function identity off name + exact argument type list, so adding two new
-- params (even with defaults) creates a brand-new overload sitting
-- alongside the old one, exactly the PGRST203 "Could not choose the best
-- candidate function" bug this project already hit once (migration
-- 20260813160000) and documented as a standing lesson. Old signatures are
-- dropped explicitly below, not left to CREATE OR REPLACE to sort out.
-- ---------------------------------------------------------------------

drop function if exists public.create_order(
  p_kit_type_id text, p_service_type text, p_employee_id uuid, p_return_address_id uuid,
  p_device_reference text, p_requested_send_date date, p_leaver_last_day date, p_bundle_id uuid,
  p_order_reference text, p_cover_tier_id text, p_pay_with_credit boolean, p_notify_employee boolean,
  p_employee_name text, p_employee_email text, p_employee_address_line1 text, p_employee_address_line2 text,
  p_employee_city text, p_employee_postcode text, p_employee_country text
);

drop function if exists public.create_internal_order(
  p_company_id uuid, p_actor_id uuid, p_kit_type_id text, p_service_type text, p_employee_id uuid,
  p_return_address_id uuid, p_device_reference text, p_requested_send_date date, p_leaver_last_day date,
  p_bundle_id uuid, p_order_reference text, p_cover_tier_id text, p_pay_with_credit boolean,
  p_notify_employee boolean, p_employee_name text, p_employee_email text, p_employee_address_line1 text,
  p_employee_address_line2 text, p_employee_city text, p_employee_postcode text, p_employee_country text
);

create function public.create_order(
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
  p_employee_country text default null,
  p_return_method text default 'drop_off',
  p_collection_date date default null
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

create function public.create_internal_order(
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
  p_employee_country text default null,
  p_return_method text default 'drop_off',
  p_collection_date date default null
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

-- Re-apply exact grants -- CREATE FUNCTION on a new signature gets Supabase's
-- default anon/authenticated EXECUTE grant again regardless of what the
-- previous (now-dropped) signature had locked down. This is the same
-- recurring trap documented repeatedly in this project's history (most
-- recently the 20260819 PUBLIC-pseudo-role incident) -- the revoke has to
-- travel with every migration that touches the function, not just the one
-- that introduced it.
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
