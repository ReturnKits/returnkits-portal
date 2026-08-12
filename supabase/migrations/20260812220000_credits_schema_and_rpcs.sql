-- Prepaid credits (20260812, architecture doc §4/§5/§16 -- scope confirmed
-- with the user: prepaid credits only, no free-kit promo yet (§22 is
-- deliberately not built -- that's what makes credits "the most complex
-- thing in the design" per §23, and nobody's asked to prepay yet outside
-- this exact feature request). Same per-unit price as self-serve kit_types
-- -- no bulk discount logic. Saved card is for speeding up buying MORE
-- credits, not for paying for individual orders directly (that stays
-- Stripe Checkout redirect, unchanged).
--
-- Design mirrors kit_types/cover_tiers/orders throughout: append-only
-- ledger (never mutated, never deleted), typed per kit_type so a laptop
-- credit can't buy a phone kit, and redemption is a single transaction
-- (insert order + debit ledger, both or neither) -- the exact Base44
-- gotcha (claimFreeKit marked itself claimed before granting the credit)
-- this project's own audit flagged, applied here even without promo.

create table public.credit_ledger (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  kit_type_id text not null references public.kit_types(id),
  transaction_type text not null check (transaction_type in ('purchase', 'redemption', 'adjustment')),
  direction text not null check (direction in ('credit', 'debit')),
  quantity integer not null check (quantity > 0),
  balance_after integer not null,
  order_id uuid references public.orders(id),
  invoice_id uuid references public.invoices(id),
  stripe_checkout_session_id text,
  reason text,
  actor_id uuid references public.users(id),
  created_at timestamptz not null default now()
);

create index credit_ledger_company_kit_type_idx on public.credit_ledger (company_id, kit_type_id);
create index credit_ledger_order_id_idx on public.credit_ledger (order_id) where order_id is not null;

alter table public.credit_ledger enable row level security;

-- Same shape as invoices_select: internal staff see everything, a company
-- sees only its own rows. No insert/update/delete policy for authenticated
-- -- append-only, and every write goes through a SECURITY DEFINER RPC or
-- the Stripe webhook's service_role, never a direct client insert.
create policy credit_ledger_select on public.credit_ledger
  for select to authenticated
  using (public.is_internal() or (company_id = public.current_company() and public.current_company() is not null));

-- orders.paid_with_credit / credit_transaction_id: which redemption (if
-- any) financed this order. Nullable/false by default so every existing
-- order is unaffected.
alter table public.orders
  add column paid_with_credit boolean not null default false,
  add column credit_transaction_id uuid references public.credit_ledger(id);

alter table public.orders add constraint orders_credit_snapshot_consistent
  check (paid_with_credit = (credit_transaction_id is not null));

-- v1 restriction: an order paid by credit can't also carry Enhanced Cover
-- -- covering the cover charge would need its own payment path (credit
-- doesn't cover it, credits are typed to kit purchases only), and
-- supporting a "partly paid by credit, partly owed by card" state is
-- exactly the kind of complexity the "prepaid credits only, no promo yet"
-- scope decision was meant to avoid. An order wanting cover pays by card
-- as normal; a credit-paid order can add cover later isn't supported
-- either -- keep it simple until someone actually asks.
alter table public.orders add constraint orders_credit_excludes_cover
  check (not (paid_with_credit and cover_tier_id is not null));

-- companies.stripe_payment_method_id: cache of a saved Stripe PaymentMethod,
-- same idea as stripe_customer_id -- an opaque reference, never actual card
-- data (that never touches our servers, only Stripe's -- see Stripe
-- Checkout's mode:'setup' flow in create-card-setup-session). Used only to
-- let Stripe Checkout preselect a saved card when buying MORE credits;
-- never used server-side to charge anything off-session in this v1.
alter table public.companies
  add column stripe_payment_method_id text;

-- create_order (Lovable, customer-facing): add optional p_pay_with_credit.
-- When true: check the company's balance for this kit type inside THIS
-- transaction (same connection, so the balance read and the debit insert
-- are atomically consistent -- two concurrent redemptions racing for the
-- last credit will serialize, not double-spend), insert the order already
-- marked paid, and insert the debit ledger row referencing it.
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
  p_pay_with_credit boolean default false
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
    payment_status, paid_with_credit
  )
  values (
    v_company, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'customer', auth.uid(), p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day,
    p_cover_tier_id, v_cover_price,
    case when p_pay_with_credit then 'paid' else 'pending' end, p_pay_with_credit
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
                        'cover_tier_id', p_cover_tier_id, 'paid_with_credit', p_pay_with_credit));

  return v_order_id;
end;
$function$;

-- create_internal_order (Retool, staff-facing): same extension, so staff
-- can redeem a company's credit on their behalf too (e.g. phone order
-- placed by support on a customer's request).
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
  p_pay_with_credit boolean default false
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
    payment_status, paid_with_credit
  )
  values (
    p_company_id, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'internal_staff', p_actor_id, p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day,
    p_cover_tier_id, v_cover_price,
    case when p_pay_with_credit then 'paid' else 'pending' end, p_pay_with_credit
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
                        'paid_with_credit', p_pay_with_credit));

  return v_order_id;
end;
$function$;

-- record_credit_purchase: the webhook-only write path for a Stripe
-- checkout.session.completed event where metadata.type = 'credit_purchase'
-- -- exact same idempotency/atomicity shape as record_stripe_payment
-- (insert into stripe_webhook_events on conflict do nothing -> if not
-- found, this event was already processed, return early having changed
-- nothing). Issues a real gapless invoice number, same sequence as order
-- payments -- a credit purchase is a real UK VAT sale, it needs a proper
-- invoice line same as anything else.
create or replace function public.record_credit_purchase(
  p_event_id text,
  p_event_type text,
  p_checkout_session_id text,
  p_payment_intent_id text,
  p_company_id uuid,
  p_kit_type_id text,
  p_quantity integer,
  p_subtotal_ex_vat_pence integer,
  p_vat_pence integer,
  p_total_inc_vat_pence integer
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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

  select coalesce(sum(case when direction = 'credit' then quantity else -quantity end), 0)
  into v_balance
  from public.credit_ledger
  where company_id = p_company_id and kit_type_id = p_kit_type_id;

  insert into public.credit_ledger (
    company_id, kit_type_id, transaction_type, direction, quantity,
    balance_after, invoice_id, stripe_checkout_session_id, reason
  ) values (
    p_company_id, p_kit_type_id, 'purchase', 'credit', p_quantity,
    v_balance + p_quantity, v_invoice_id, p_checkout_session_id, 'Credit pack purchase'
  );

  return v_invoice_id;
end;
$$;

revoke all on function public.record_credit_purchase(
  text, text, text, text, uuid, text, integer, integer, integer, integer
) from public;

-- record_card_setup: webhook-only, fires on a completed mode:'setup'
-- Checkout Session. Caches the PaymentMethod id (an opaque Stripe
-- reference, never actual card data) and sets it as the customer's Stripe
-- default payment method so future credit-purchase Checkout Sessions
-- automatically offer it as a one-click saved option -- no embedded
-- Stripe Elements or off-session charging needed for this v1.
create or replace function public.record_card_setup(
  p_company_id uuid,
  p_stripe_payment_method_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before jsonb;
begin
  select to_jsonb(c) into v_before from public.companies c where id = p_company_id;

  update public.companies
  set stripe_payment_method_id = p_stripe_payment_method_id
  where id = p_company_id;

  perform public.log_audit(
    null, 'company.card_setup', 'companies', p_company_id, v_before,
    (select to_jsonb(c) from public.companies c where c.id = p_company_id)
  );
end;
$$;

revoke all on function public.record_card_setup(uuid, text) from public;

-- cancel_order: extend to restore the credit when the order being
-- cancelled was paid_with_credit -- CLAUDE.md's rule ("purchased credits
-- are restored; promo credits are forfeited") applies here with every
-- credit being a purchased one, since promo isn't built. A compensating
-- ledger row, never mutating the original debit -- same append-only
-- discipline as everything else in the ledger.
create or replace function public.cancel_order(
  p_order_id uuid,
  p_actor_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_before jsonb;
  v_log_entry jsonb;
  v_balance integer;
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
    select coalesce(sum(case when direction = 'credit' then quantity else -quantity end), 0)
    into v_balance
    from public.credit_ledger
    where company_id = v_order.company_id and kit_type_id = v_order.kit_type_id;

    insert into public.credit_ledger (
      company_id, kit_type_id, transaction_type, direction, quantity,
      balance_after, order_id, actor_id, reason
    ) values (
      v_order.company_id, v_order.kit_type_id, 'adjustment', 'credit', 1,
      v_balance + 1, p_order_id, p_actor_id, 'Restored: order ' || v_order.reference || ' cancelled'
    );
  end if;

  perform public.log_audit(
    p_actor_id, 'order.cancel', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;

revoke all on function public.cancel_order(uuid, uuid, text) from public;
revoke execute on function public.cancel_order(uuid, uuid, text) from anon, authenticated;
