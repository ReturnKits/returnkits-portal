-- Enhanced Cover (20260812, §20 of the architecture doc): carrier
-- declared-value passthrough add-on, never referred to as "insurance"
-- (FCA reasons -- enhanced liability within the carriage service is not a
-- regulated insurance product, which is also why it's standard-rated VAT
-- rather than IPT-exempt). Was fully designed in the docs but never built
-- until now: no table, no UI, nothing live. Building it because real
-- enterprise pricing has already been quoted assuming it exists.
--
-- Same pattern as kit_types throughout: a table rather than hardcoded
-- tiers (so a price or VAT-rate change is a data change, not a code
-- change), snapshotted onto the order at creation time (so a later price
-- change never rewrites historical orders/invoices).

create table public.cover_tiers (
  id text primary key,
  label text not null,
  max_value_pence integer not null check (max_value_pence > 0),
  price_ex_vat_pence integer not null check (price_ex_vat_pence >= 0),
  vat_rate numeric not null default 0.20,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.cover_tiers (id, label, max_value_pence, price_ex_vat_pence) values
  ('up_to_500',   'Enhanced Cover (up to £500)',   50000,  500),
  ('up_to_1000',  'Enhanced Cover (up to £1,000)', 100000, 1000),
  ('up_to_2000',  'Enhanced Cover (up to £2,000)', 200000, 2000);

alter table public.cover_tiers enable row level security;

-- Same shape as kit_types_select_all: every authenticated user can read
-- the catalogue (needed for checkout), the app filters to active=true
-- client-side, and there's deliberately no write policy -- tiers are
-- managed by migration/staff SQL, not through the app.
create policy cover_tiers_select_all on public.cover_tiers
  for select to authenticated using (true);

-- orders.cover_tier_id/cover_price_ex_vat_pence: nullable because cover is
-- an optional add-on, snapshotted together (both null or both set) so a
-- later cover_tiers price change can't retroactively alter what an order
-- actually paid.
alter table public.orders
  add column cover_tier_id text references public.cover_tiers(id),
  add column cover_price_ex_vat_pence integer,
  add column cover_claim_filed_at timestamptz;

alter table public.orders add constraint orders_cover_snapshot_consistent
  check ((cover_tier_id is null) = (cover_price_ex_vat_pence is null));

alter table public.orders add constraint orders_cover_claim_requires_cover
  check (cover_claim_filed_at is null or cover_tier_id is not null);

-- create_order (Lovable, customer-facing): add optional p_cover_tier_id,
-- same validate-then-snapshot shape as kit_type_id.
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
  p_cover_tier_id text default null::text
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
begin
  if v_company is null then
    raise exception 'Must belong to a company';
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

  v_ref := public.next_reference_number(v_prefix);

  insert into public.orders (
    company_id, bundle_id, reference, order_reference, kit_type_id, service_type,
    source, created_by, employee_id, return_address_id, device_reference,
    price_ex_vat_pence, requested_send_date, leaver_last_day,
    cover_tier_id, cover_price_ex_vat_pence
  )
  values (
    v_company, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'customer', auth.uid(), p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day,
    p_cover_tier_id, v_cover_price
  )
  returning id into v_order_id;

  perform public.log_audit(auth.uid(), 'order.create', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'cover_tier_id', p_cover_tier_id));

  return v_order_id;
end;
$function$;

-- create_internal_order (Retool, staff-facing): same extension.
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
  p_cover_tier_id text default null::text
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
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'create_internal_order can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

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

  v_ref := public.next_reference_number(v_prefix);

  insert into public.orders (
    company_id, bundle_id, reference, order_reference, kit_type_id, service_type,
    source, created_by, employee_id, return_address_id, device_reference,
    price_ex_vat_pence, requested_send_date, leaver_last_day,
    cover_tier_id, cover_price_ex_vat_pence
  )
  values (
    p_company_id, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'internal_staff', p_actor_id, p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day,
    p_cover_tier_id, v_cover_price
  )
  returning id into v_order_id;

  perform public.log_audit(p_actor_id, 'order.create_internal', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'company_id', p_company_id, 'cover_tier_id', p_cover_tier_id));

  return v_order_id;
end;
$function$;

-- flag_cover_claim (Retool, staff-only): deliberately minimal per the
-- architecture doc's "claims flow is undesigned" note. This doesn't file
-- anything with the carrier -- that's still a phone call/email a human
-- makes -- it just gives staff a record instead of it living only in an
-- inbox, and a visible marker on the order.
create or replace function public.flag_cover_claim(
  p_order_id uuid,
  p_actor_id uuid,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_order public.orders%rowtype;
  v_before jsonb;
  v_log_entry jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'flag_cover_claim can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if v_order.cover_tier_id is null then
    raise exception 'Order % has no Enhanced Cover to claim against', p_order_id;
  end if;

  if v_order.cover_claim_filed_at is not null then
    raise exception 'Order % already has a claim on file (filed %)', p_order_id, v_order.cover_claim_filed_at;
  end if;

  v_before := to_jsonb(v_order);

  v_log_entry := jsonb_build_object(
    'action', 'cover_claim_flagged',
    'actor_id', p_actor_id,
    'at', now(),
    'detail', jsonb_build_object('notes', p_notes, 'cover_tier_id', v_order.cover_tier_id)
  );

  update public.orders
  set cover_claim_filed_at = now(),
      fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
  where id = p_order_id;

  perform public.log_audit(
    p_actor_id, 'order.flag_cover_claim', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;

revoke all on function public.flag_cover_claim(uuid, uuid, text) from public;
revoke execute on function public.flag_cover_claim(uuid, uuid, text) from anon, authenticated;
