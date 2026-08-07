-- ============================================================================
-- Phase 4: the Retool write API — mark_order_dispatched() and
-- create_internal_order(). Hand-written, never generated (CLAUDE.md).
--
-- Auth model (confirmed with the user): Retool holds ONE privileged
-- connection (the service_role key, same trust boundary the getting-started
-- doc already describes for its direct Postgres read connection) rather
-- than each internal staff member having Retool pass through their own
-- Supabase session. Accountability comes from an explicit "acting as"
-- picklist in the Retool UI (p_actor_id below), validated server-side
-- against real internal_admin/internal_ops rows -- not from auth.uid(),
-- which would be meaningless for a service_role-authenticated call anyway
-- (service_role requests carry no app_role/company_id claim; that claim
-- only exists on tokens minted through the normal user auth flow).
--
-- Both functions therefore:
--   1. Assert auth.role() = 'service_role' explicitly (defense in depth --
--      EXECUTE is also revoked from anon/authenticated below, same
--      belt-and-braces pattern as record_stripe_payment's lockdown).
--   2. Validate p_actor_id really is an internal_admin/internal_ops user
--      before trusting it for the audit trail -- Retool's picklist should
--      only ever offer real staff, but the function doesn't take that on
--      faith from the caller.
-- ============================================================================

create or replace function public.assert_internal_actor(p_actor_id uuid)
returns void
language plpgsql
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.users
    where id = p_actor_id and role in ('internal_admin', 'internal_ops')
  ) then
    raise exception 'p_actor_id % is not an internal staff member', p_actor_id;
  end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- mark_order_dispatched — sets outbound_* or return_* tracking columns
-- (inferred from the order's own service_type -- an order only ever has one
-- active leg in this flat model, architecture §4) and advances
-- fulfilment_status. Records to both audit_log (internal-facing) and
-- fulfilment_log (customer-facing timeline, read directly by Lovable).
-- ----------------------------------------------------------------------------
create or replace function public.mark_order_dispatched(
  p_order_id uuid,
  p_actor_id uuid,
  p_courier text,
  p_tracking_number text,
  p_tracking_url text default null
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
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'mark_order_dispatched can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if v_order.fulfilment_status <> 'awaiting_dispatch' then
    raise exception 'Order % is not awaiting dispatch (currently %)', p_order_id, v_order.fulfilment_status;
  end if;

  v_before := to_jsonb(v_order);

  v_log_entry := jsonb_build_object(
    'action', 'dispatched',
    'actor_id', p_actor_id,
    'at', now(),
    'detail', jsonb_build_object('courier', p_courier, 'tracking_number', p_tracking_number)
  );

  if v_order.service_type = 'return' then
    update public.orders
    set fulfilment_status = 'dispatched',
        return_courier = p_courier,
        return_tracking_number = p_tracking_number,
        return_tracking_url = p_tracking_url,
        fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
    where id = p_order_id;
  else
    update public.orders
    set fulfilment_status = 'dispatched',
        outbound_courier = p_courier,
        outbound_tracking_number = p_tracking_number,
        outbound_tracking_url = p_tracking_url,
        fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
    where id = p_order_id;
  end if;

  perform public.log_audit(
    p_actor_id, 'order.dispatch', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;

revoke all on function public.mark_order_dispatched(uuid, uuid, text, text, text) from public;
revoke execute on function public.mark_order_dispatched(uuid, uuid, text, text, text) from anon, authenticated;

-- ----------------------------------------------------------------------------
-- create_internal_order — the manual-order-creation path for staff acting
-- on behalf of a company (source = 'internal_staff'). Mirrors create_order()
-- exactly (same reference generation, same validation), except company_id
-- is an explicit parameter rather than current_company() -- there is no
-- "current company" for a service_role-authenticated Retool call, staff
-- pick the company explicitly in the UI.
-- ----------------------------------------------------------------------------
create or replace function public.create_internal_order(
  p_company_id uuid,
  p_actor_id uuid,
  p_kit_type_id text,
  p_service_type text,
  p_employee_id uuid,
  p_return_address_id uuid default null,
  p_device_reference text default null,
  p_requested_send_date date default null,
  p_leaver_last_day date default null,
  p_bundle_id uuid default null,
  p_order_reference text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prefix text;
  v_price integer;
  v_active boolean;
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

  v_ref := public.next_reference_number(v_prefix);

  insert into public.orders (
    company_id, bundle_id, reference, order_reference, kit_type_id, service_type,
    source, created_by, employee_id, return_address_id, device_reference,
    price_ex_vat_pence, requested_send_date, leaver_last_day
  )
  values (
    p_company_id, p_bundle_id, v_ref, p_order_reference, p_kit_type_id, p_service_type,
    'internal_staff', p_actor_id, p_employee_id, p_return_address_id, p_device_reference,
    v_price, p_requested_send_date, p_leaver_last_day
  )
  returning id into v_order_id;

  perform public.log_audit(p_actor_id, 'order.create_internal', 'orders', v_order_id, null,
    jsonb_build_object('reference', v_ref, 'kit_type_id', p_kit_type_id, 'service_type', p_service_type,
                        'company_id', p_company_id));

  return v_order_id;
end;
$$;

revoke all on function public.create_internal_order(
  uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text
) from public;
revoke execute on function public.create_internal_order(
  uuid, uuid, text, text, uuid, uuid, text, date, date, uuid, text
) from anon, authenticated;
