-- Backfilled from the hosted project (applied there directly via apply_migration)
-- so a local `db reset` reproduces hosted.

-- Staff-only RPC letting Retool edit every field shown on the customer-facing order detail
-- page: reference, device reference, dates, employee, return address, notify toggle, and
-- (per explicit user decision 20260915) kit type / price / cover tier, even post-payment.
-- Deliberately does NOT touch payment_status, fulfilment_status, invoice_id, paid_with_credit,
-- credit_transaction_id, cover_paid_separately, return_method, collection_date, or reference —
-- those have their own dedicated flows (Mark as Paid, Mark Dispatched, Cancel, Edit tracking,
-- Flag claim) and are intentionally out of scope here.
--
-- Verified before writing this: trg_order_paid_send_confirmation and
-- trg_order_dispatched_send_email only fire when payment_status/fulfilment_status themselves
-- transition into 'paid'/'dispatched' (checked inside the trigger function body, not just
-- "any UPDATE fired"). This RPC never sets either column, so it cannot trigger those emails —
-- confirmed structurally, not just assumed.
create or replace function public.update_order_details(
  p_order_id uuid,
  p_actor_id uuid,
  p_order_reference text default null,
  p_device_reference text default null,
  p_requested_send_date date default null,
  p_leaver_last_day date default null,
  p_kit_type_id text default null,
  p_price_ex_vat_pence integer default null,
  p_cover_tier_id text default null,
  p_cover_price_ex_vat_pence integer default null,
  p_employee_id uuid default null,
  p_employee_name text default null,
  p_employee_email text default null,
  p_employee_address_line1 text default null,
  p_employee_address_line2 text default null,
  p_employee_city text default null,
  p_employee_postcode text default null,
  p_employee_country text default null,
  p_return_address_id uuid default null,
  p_notify_employee boolean default false
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_order public.orders%rowtype;
  v_before jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'update_order_details can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if p_employee_id is not null and p_employee_name is not null then
    raise exception 'Provide either an existing employee or manual employee details, not both';
  end if;

  if p_employee_id is null and p_employee_name is null then
    raise exception 'An employee is required — pick an existing one or enter details manually';
  end if;

  if p_employee_id is not null then
    if not exists (select 1 from public.employees where id = p_employee_id and company_id = v_order.company_id) then
      raise exception 'Employee not found for this company';
    end if;
  else
    if length(trim(p_employee_name)) = 0 then
      raise exception 'Employee name cannot be blank';
    end if;
  end if;

  if p_return_address_id is not null
     and not exists (select 1 from public.addresses where id = p_return_address_id and company_id = v_order.company_id) then
    raise exception 'Return address not found for this company';
  end if;

  if p_kit_type_id is null then
    raise exception 'Kit type is required';
  end if;

  if not exists (select 1 from public.kit_types where id = p_kit_type_id) then
    raise exception 'Unknown kit type: %', p_kit_type_id;
  end if;

  if p_price_ex_vat_pence is null then
    raise exception 'Price is required';
  end if;

  if p_cover_tier_id is not null
     and not exists (select 1 from public.cover_tiers where id = p_cover_tier_id) then
    raise exception 'Unknown cover tier: %', p_cover_tier_id;
  end if;

  v_before := to_jsonb(v_order);

  update public.orders
  set
    order_reference = nullif(trim(coalesce(p_order_reference, '')), ''),
    device_reference = nullif(trim(coalesce(p_device_reference, '')), ''),
    requested_send_date = p_requested_send_date,
    leaver_last_day = p_leaver_last_day,
    kit_type_id = p_kit_type_id,
    price_ex_vat_pence = p_price_ex_vat_pence,
    cover_tier_id = p_cover_tier_id,
    cover_price_ex_vat_pence = case when p_cover_tier_id is null then null else p_cover_price_ex_vat_pence end,
    employee_id = p_employee_id,
    employee_name = nullif(trim(coalesce(p_employee_name, '')), ''),
    employee_email = nullif(trim(coalesce(p_employee_email, '')), ''),
    employee_address_line1 = nullif(trim(coalesce(p_employee_address_line1, '')), ''),
    employee_address_line2 = nullif(trim(coalesce(p_employee_address_line2, '')), ''),
    employee_city = nullif(trim(coalesce(p_employee_city, '')), ''),
    employee_postcode = nullif(trim(coalesce(p_employee_postcode, '')), ''),
    employee_country = case when p_employee_id is not null then null else coalesce(nullif(trim(p_employee_country), ''), 'GB') end,
    return_address_id = p_return_address_id,
    notify_employee = coalesce(p_notify_employee, false)
  where id = p_order_id;

  perform public.log_audit(
    p_actor_id, 'order.update_details', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$function$;

revoke all on function public.update_order_details(
  uuid, uuid, text, text, date, date, text, integer, text, integer,
  uuid, text, text, text, text, text, text, text, uuid, boolean
) from public, anon, authenticated;

grant execute on function public.update_order_details(
  uuid, uuid, text, text, date, date, text, integer, text, integer,
  uuid, text, text, text, text, text, text, text, uuid, boolean
) to service_role;
