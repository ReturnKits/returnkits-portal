-- Manual, one-off employee entry on orders (20260813).
--
-- The user wants to type an employee's name/address directly into the New
-- Order form for a one-off recipient, WITHOUT it being saved as a reusable
-- row in the employees directory. Confirmed explicitly: "i want them to be
-- able to add an address manually without saving the record."
--
-- Until now orders.employee_id was NOT NULL, always pointing at a real
-- public.employees row -- there was no way to place an order without first
-- creating (or reusing) a directory entry. This migration adds a second,
-- parallel path: order-level snapshot columns that hold the same shape of
-- data (name/email/address) directly on the order, used instead of a
-- employee_id FK when the orderer chooses "enter manually" in Lovable.
--
-- Design:
--   - employee_id becomes nullable.
--   - New columns: employee_name, employee_email, employee_address_line1/2,
--     employee_city, employee_postcode, employee_country. Deliberately
--     named differently from employees.full_name/employees.address_line1
--     etc. (not just "full_name" reused) so it's unambiguous at a glance
--     that these are order-level snapshot fields, not a join.
--   - orders_employee_source_check: exactly one of employee_id or
--     employee_name is set. Never both (ambiguous which is authoritative),
--     never neither (every order still needs SOME employee info -- that
--     requirement doesn't change, only where it can come from).
--   - No DB-level requirement that ship_to_new_employee manual entries
--     include an address (mirrors the existing employee_id path, where
--     employees.address_line1 is nullable and never enforced either --
--     deliberately not introducing asymmetric strictness between the two
--     paths). create_order/create_internal_order still validate
--     employee_name is non-blank when used, same floor employees.full_name
--     already has as NOT NULL.
--   - country defaults to 'GB' for manual entries, matching
--     employees.country's own default, applied in the RPC (not a column
--     default here, since it should only apply when the manual path is
--     actually used).
--
-- Downstream consumers updated in the same batch of work (not by this
-- migration): send-order-email and generate-print-pack both now resolve
-- employee name/email/address from EITHER the employees join OR these
-- snapshot columns, whichever is populated.

alter table public.orders alter column employee_id drop not null;

alter table public.orders add column if not exists employee_name text;
alter table public.orders add column if not exists employee_email text;
alter table public.orders add column if not exists employee_address_line1 text;
alter table public.orders add column if not exists employee_address_line2 text;
alter table public.orders add column if not exists employee_city text;
alter table public.orders add column if not exists employee_postcode text;
alter table public.orders add column if not exists employee_country text;

alter table public.orders add constraint orders_employee_source_check
  check (
    (employee_id is not null and employee_name is null)
    or
    (employee_id is null and employee_name is not null)
  );

comment on column public.orders.employee_id is
  'Set when the orderer picked an existing employees row. Mutually exclusive with employee_name (orders_employee_source_check) -- exactly one employee source per order, never both, never neither.';
comment on column public.orders.employee_name is
  'Set when the orderer typed a one-off employee manually (20260813) instead of picking from the directory -- NOT written to public.employees, exists only as an order-level snapshot. Mutually exclusive with employee_id.';

-- ---------------------------------------------------------------------------
-- create_order (Lovable-facing, authenticated portal users)
-- ---------------------------------------------------------------------------

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
  p_employee_country text default null::text
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

  if p_cover_tier_id is not null then
    select price_ex_vat_pence, active into v_cover_price, v_cover_active
    from public.cover_tiers where id = p_cover_tier_id;

    if v_cover_price is null then
      raise exception 'Unknown cover tier: %', p_cover_tier_id;
    end if;

    if not v_cover_active then
      raise exception 'Cover tier % is not currently available', p_cover_tier_id;
    end if;
  end if;

  if p_pay_with_credit then
    select coalesce(sum(case when direction = 'credit' then quantity else -quantity end), 0)
    into v_balance
    from public.credit_ledger
    where company_id = v_company and kit_type_id = p_kit_type_id;

    if v_balance < 1 then
      raise exception 'Insufficient % credit balance (have %, need 1)', p_kit_type_id, v_balance;
    end if;
  end if;

  v_ref := public.next_reference_number(v_prefix);

  insert into public.orders (
    company_id, bundle_id, reference, order_reference, kit_type_id, service_type,
    source, created_by, employee_id, return_address_id, device_reference,
    price_ex_vat_pence, requested_send_date, leaver_last_day,
    cover_tier_id, cover_price_ex_vat_pence,
    payment_status, paid_with_credit, notify_employee,
    employee_name, employee_email, employee_address_line1, employee_address_line2,
    employee_city, employee_postcode, employee_country
  )
  values (
    v_company, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'customer', auth.uid(), p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day,
    p_cover_tier_id, v_cover_price,
    case when p_pay_with_credit then 'paid' else 'pending' end, p_pay_with_credit, p_notify_employee,
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
    insert into public.credit_ledger (
      company_id, kit_type_id, transaction_type, direction, quantity,
      balance_after, order_id, actor_id, reason
    ) values (
      v_company, p_kit_type_id, 'redemption', 'debit', 1,
      v_balance - 1, v_order_id, auth.uid(), 'Redeemed for order ' || v_ref
    )
    returning id into v_ledger_id;

    update public.orders set credit_transaction_id = v_ledger_id where id = v_order_id;
  end if;

  perform public.log_audit(auth.uid(), 'order.create', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'cover_tier_id', p_cover_tier_id, 'paid_with_credit', p_pay_with_credit,
                        'notify_employee', p_notify_employee, 'manual_employee', p_employee_id is null));

  return v_order_id;
end;
$function$;

-- ---------------------------------------------------------------------------
-- create_internal_order (Retool-facing, service_role only)
-- ---------------------------------------------------------------------------

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
  p_employee_country text default null::text
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

  if p_cover_tier_id is not null then
    select price_ex_vat_pence, active into v_cover_price, v_cover_active
    from public.cover_tiers where id = p_cover_tier_id;

    if v_cover_price is null then
      raise exception 'Unknown cover tier: %', p_cover_tier_id;
    end if;

    if not v_cover_active then
      raise exception 'Cover tier % is not currently available', p_cover_tier_id;
    end if;
  end if;

  if p_pay_with_credit then
    select coalesce(sum(case when direction = 'credit' then quantity else -quantity end), 0)
    into v_balance
    from public.credit_ledger
    where company_id = p_company_id and kit_type_id = p_kit_type_id;

    if v_balance < 1 then
      raise exception 'Insufficient % credit balance (have %, need 1)', p_kit_type_id, v_balance;
    end if;
  end if;

  v_ref := public.next_reference_number(v_prefix);

  insert into public.orders (
    company_id, bundle_id, reference, order_reference, kit_type_id, service_type,
    source, created_by, employee_id, return_address_id, device_reference,
    price_ex_vat_pence, requested_send_date, leaver_last_day,
    cover_tier_id, cover_price_ex_vat_pence,
    payment_status, paid_with_credit, notify_employee,
    employee_name, employee_email, employee_address_line1, employee_address_line2,
    employee_city, employee_postcode, employee_country
  )
  values (
    p_company_id, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'internal_staff', p_actor_id, p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day,
    p_cover_tier_id, v_cover_price,
    case when p_pay_with_credit then 'paid' else 'pending' end, p_pay_with_credit, p_notify_employee,
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
    insert into public.credit_ledger (
      company_id, kit_type_id, transaction_type, direction, quantity,
      balance_after, order_id, actor_id, reason
    ) values (
      p_company_id, p_kit_type_id, 'redemption', 'debit', 1,
      v_balance - 1, v_order_id, p_actor_id, 'Redeemed for order ' || v_ref
    )
    returning id into v_ledger_id;

    update public.orders set credit_transaction_id = v_ledger_id where id = v_order_id;
  end if;

  perform public.log_audit(p_actor_id, 'order.create_internal', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'company_id', p_company_id, 'cover_tier_id', p_cover_tier_id,
                        'paid_with_credit', p_pay_with_credit, 'notify_employee', p_notify_employee,
                        'manual_employee', p_employee_id is null));

  return v_order_id;
end;
$function$;
