-- create_credit_order_with_paid_cover(): the webhook-only RPC that actually
-- implements "pay for the kit with credit, pay for Enhanced Cover by card,
-- same order" (see the previous migration for the full design reasoning).
--
-- Deliberately NOT a variant of create_order() -- create_order() explicitly
-- rejects p_pay_with_credit alongside a non-null p_cover_tier_id (see its
-- guard: "Cannot pay with credit and add Enhanced Cover on the same
-- order"), and that guard stays exactly as-is for every other caller. This
-- is a separate, narrower function for one specific, atomic case: called
-- from stripe-webhook, and only from there, after Stripe has already
-- confirmed the cover payment.
--
-- Mirrors record_stripe_payment/record_credit_purchase's idempotency
-- pattern exactly (stripe_webhook_events insert ... on conflict do
-- nothing; a duplicate event_id is a silent no-op, not an error) and
-- create_order's credit-redemption pattern exactly (advisory lock on
-- company+kit_type before reading the balance, so two concurrent
-- redemptions for the last credit still serialize rather than double-spend
-- -- same discipline this project's audit already flagged once as a real
-- bug class). The credit_ledger row is inserted before the orders row (with
-- order_id left null, backfilled after) for the same reason
-- 20260813180000 fixed create_order the same way: orders_credit_snapshot_
-- consistent is a non-deferrable CHECK, so credit_transaction_id must be
-- bound at INSERT time, not UPDATEd in afterward.
--
-- Accepted edge case, not engineered around (consistent with this
-- project's existing "no automated refunds" stance): the credit balance is
-- checked at payment-confirmation time, not reserved at checkout-session-
-- creation time. If a customer starts a cover checkout while a credit is
-- available, then someone else spends the company's last credit of that
-- kit type before the customer finishes paying, this function raises and
-- the order is never created -- but the card charge for cover already
-- succeeded. That specific combination has to be resolved the same way
-- every other refund in this app is: a human, manually, in the Stripe
-- dashboard. Narrow window, same remedy already relied on elsewhere.

create or replace function public.create_credit_order_with_paid_cover(
  p_event_id text,
  p_event_type text,
  p_checkout_session_id text,
  p_payment_intent_id text,
  p_company_id uuid,
  p_created_by uuid,
  p_kit_type_id text,
  p_service_type text,
  p_cover_tier_id text,
  p_cover_subtotal_ex_vat_pence integer,
  p_cover_vat_pence integer,
  p_cover_total_inc_vat_pence integer,
  p_employee_id uuid default null,
  p_return_address_id uuid default null,
  p_device_reference text default null,
  p_requested_send_date date default null,
  p_leaver_last_day date default null,
  p_bundle_id uuid default null,
  p_order_reference text default null,
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

-- Same hardened pattern as every other webhook-only RPC in this project
-- (see the 20260813170000 and 20260816180000 lockdown incidents): grant
-- EXECUTE to service_role only, and explicitly revoke from public/anon/
-- authenticated rather than relying on a bare "revoke all from public"
-- (which does not touch the PUBLIC pseudo-role's implicit function grant).
grant execute on function public.create_credit_order_with_paid_cover(
  text, text, text, text, uuid, uuid, text, text, text, integer, integer, integer,
  uuid, uuid, text, date, date, uuid, text, boolean, text, text, text, text, text, text, text
) to service_role;

revoke execute on function public.create_credit_order_with_paid_cover(
  text, text, text, text, uuid, uuid, text, text, text, integer, integer, integer,
  uuid, uuid, text, date, date, uuid, text, boolean, text, text, text, text, text, text, text
) from public, anon, authenticated;
