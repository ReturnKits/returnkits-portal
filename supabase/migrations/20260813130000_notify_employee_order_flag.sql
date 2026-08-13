-- Per-order control over the employee-facing passive notifications
-- (20260813, follow-up to 20260813120000_employee_facing_notifications.sql).
--
-- The employee-facing dispatched/checkin_sent copies previously fired
-- automatically whenever the order had an employee email on file, gated
-- only by the company-level notification_preferences toggle (which mutes
-- BOTH the customer and employee copies of an event type together). The
-- user wanted a per-order control instead: the person placing the order
-- decides, order by order, whether the named employee gets nudged.
--
-- Scope locked with the user:
--   - Off by default. An order with no explicit opt-in sends no employee
--     copy, full stop -- conservative, no quiet-failure risk from someone
--     forgetting to tick a box when they didn't want the employee emailed.
--   - One flag, not two. Covers both 'dispatched' and 'checkin_sent'
--     together -- matches how the feature was originally scoped as a
--     single "passive nudge" concept, not two independently-tunable ones.
--   - Set at order creation only, via create_order/create_internal_order.
--     No dedicated edit RPC -- nobody asked to change it after the fact,
--     and every other per-order snapshot in this schema (kit price, cover
--     tier, credit redemption) follows the same "decided at creation,
--     immutable after" pattern.
--
-- This sits ON TOP OF, not instead of, the existing notification_preferences
-- gate and the employee-has-no-email no-op in sendEmployeeCopy: both must
-- still be true (or absent) for the copy to actually send. This flag is
-- the order-level override; the other two are the company-level and
-- data-availability gates.

alter table public.orders add column if not exists notify_employee boolean not null default false;

comment on column public.orders.notify_employee is
  'Set at order creation only (create_order / create_internal_order''s p_notify_employee param), default false. When true, the employee named on the order (employee_id -> employees.email) also receives the passive dispatched/checkin_sent nudges send-order-email sends alongside the customer-facing email -- still subject to the company-level notification_preferences toggle and to the employee having an email on file. No dedicated edit RPC: decided once, at creation, same pattern as price_ex_vat_pence/cover_tier_id/paid_with_credit.';

-- ---------------------------------------------------------------------------
-- create_order (Lovable-facing, authenticated portal users)
-- ---------------------------------------------------------------------------

create or replace function public.create_order(
  p_kit_type_id text,
  p_service_type text,
  p_employee_id uuid,
  p_return_address_id uuid default null::uuid,
  p_device_reference text default null::text,
  p_requested_send_date date default null::date,
  p_leaver_last_day date default null::date,
  p_bundle_id uuid default null::uuid,
  p_order_reference text default null::text,
  p_cover_tier_id text default null::text,
  p_pay_with_credit boolean default false,
  p_notify_employee boolean default false
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
begin
  if v_company is null then
    raise exception 'Must belong to a company';
  end if;

  if p_pay_with_credit and p_cover_tier_id is not null then
    raise exception 'Cannot pay with credit and add Enhanced Cover on the same order';
  end if;

  if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_company) then
    raise exception 'Employee not found for this company';
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
    payment_status, paid_with_credit, notify_employee
  )
  values (
    v_company, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'customer', auth.uid(), p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day,
    p_cover_tier_id, v_cover_price,
    case when p_pay_with_credit then 'paid' else 'pending' end, p_pay_with_credit, p_notify_employee
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
                        'notify_employee', p_notify_employee));

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
  p_employee_id uuid,
  p_return_address_id uuid default null::uuid,
  p_device_reference text default null::text,
  p_requested_send_date date default null::date,
  p_leaver_last_day date default null::date,
  p_bundle_id uuid default null::uuid,
  p_order_reference text default null::text,
  p_cover_tier_id text default null::text,
  p_pay_with_credit boolean default false,
  p_notify_employee boolean default false
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

  if not exists (select 1 from public.employees where id = p_employee_id and company_id = p_company_id) then
    raise exception 'Employee not found for this company';
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
    payment_status, paid_with_credit, notify_employee
  )
  values (
    p_company_id, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'internal_staff', p_actor_id, p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day,
    p_cover_tier_id, v_cover_price,
    case when p_pay_with_credit then 'paid' else 'pending' end, p_pay_with_credit, p_notify_employee
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
                        'paid_with_credit', p_pay_with_credit, 'notify_employee', p_notify_employee));

  return v_order_id;
end;
$function$;
