-- supabase/migrations/20260819240000_customer_cancel_pending_order_rpc.sql
--
-- Customer-facing self-cancel, added 20260819 in direct response to: "when
-- customers create an order, the order is created first then they can pay
-- for it after, before they can pay, give them the option to cancel." Until
-- now the only way to cancel an order was cancel_order() -- staff-only,
-- service_role-gated, exposed in Retool -- so a customer who created an
-- order and changed their mind before paying had no self-serve way out.
--
-- Deliberately a SEPARATE function from cancel_order(), not a relaxed
-- version of it: cancel_order()'s whole design (see 20260812190000) assumes
-- a staff actor and, since the credits migration, can restore a spent
-- credit -- neither applies here. This function only ever fires on an order
-- that has payment_status = 'pending', which by construction can never be
-- paid_with_credit = true (create_order()'s credit-redemption path always
-- sets payment_status = 'paid' in the same transaction as the insert, see
-- 20260813180000) -- so there is no credit to restore and no "was this
-- refunded outside the app" question to worry about. Nothing has been
-- charged yet; this is a pure pre-payment change of mind, not a
-- cancellation-with-money-involved, which is why it doesn't need staff
-- involvement or the no-automated-refunds carve-out at all.
--
-- Who can call it: the RLS shape on public.orders already draws a line
-- between "can see" (any company member, orders_select) and "can directly
-- UPDATE the row" (company_admin/internal only, orders_update_admin_or_
-- internal) -- but neither of those is quite right for this action either.
-- Restricting to company_admin only would block the very person who placed
-- the order (any company_member can call create_order()) from undoing their
-- own not-yet-paid action, which defeats the point of the request. Opening
-- it to every company member would let a colleague cancel someone else's
-- in-flight order for no reason. Landed on: the order's own creator
-- (orders.created_by = auth.uid()), OR a company_admin, OR internal staff --
-- mirrors "you can always undo your own thing, and an admin can always
-- intervene," without the wide-open "anyone in the company" grant.
--
-- Auth model is therefore genuinely different from every other RPC in this
-- file: not service_role-gated (there is no staff actor here at all), but
-- also not the "anyone with a valid session" shape confirm_received() uses
-- -- it derives the caller from auth.uid() (like every Lovable-facing RPC)
-- and checks company + creator/admin inside the function body, the same way
-- create_order() derives company_id from the session rather than trusting a
-- caller-supplied value.

create or replace function public.cancel_pending_order(
  p_order_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_actor uuid := auth.uid();
  v_before jsonb;
  v_log_entry jsonb;
begin
  if v_actor is null then
    raise exception 'Must be signed in to cancel an order';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order not found';
  end if;

  -- Don't leak whether an order exists in another company -- same "not
  -- found" wording whether it's genuinely missing or just not this caller's.
  if not (public.is_internal() or v_order.company_id = public.current_company()) then
    raise exception 'Order not found';
  end if;

  if not (
    public.is_internal()
    or public.current_role() = 'company_admin'
    or v_order.created_by = v_actor
  ) then
    raise exception 'Only the person who placed this order, or a company admin, can cancel it';
  end if;

  if v_order.payment_status <> 'pending' then
    raise exception 'This order has already been paid (or already cancelled) and can no longer be self-cancelled -- contact support if you need to cancel a paid order';
  end if;

  if v_order.fulfilment_status <> 'awaiting_dispatch' then
    raise exception 'This order cannot be cancelled -- it is already in progress';
  end if;

  v_before := to_jsonb(v_order);

  v_log_entry := jsonb_build_object(
    'action', 'cancelled',
    'actor_id', v_actor,
    'at', now(),
    'detail', jsonb_build_object('reason', p_reason, 'was_paid', false, 'cancelled_by', 'customer')
  );

  update public.orders
  set fulfilment_status = 'cancelled',
      payment_status = 'cancelled',
      cancel_reason = p_reason,
      fulfilment_log = fulfilment_log || jsonb_build_array(v_log_entry)
  where id = p_order_id;

  perform public.log_audit(
    v_actor, 'order.cancel_pending', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;

-- A signed-in portal user is meant to call this directly (same shape as
-- create_order/accept_invite/confirm_received/create_bundle/
-- create_company_and_admin) -- 'authenticated' stays granted, 'PUBLIC' and
-- 'anon' are revoked, matching the exact lesson from 20260819120000 (revoke
-- from PUBLIC explicitly, not just anon/authenticated by name).
revoke execute on function public.cancel_pending_order(uuid, text) from public, anon;
grant execute on function public.cancel_pending_order(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Add cancel_pending_order to internal_function_grant_leaks' allowlist --
-- otherwise the standing regression check (tests/rls.test.ts) would flag
-- its intentional 'authenticated' grant as a leak. Same drop+recreate shape
-- as every prior edit to this view (20260816180000, 20260819120000): only
-- the allowlist array changes.
-- ---------------------------------------------------------------------
drop view if exists public.internal_function_grant_leaks;

create view public.internal_function_grant_leaks
with (security_invoker = true) as
select
  p.proname as routine_name,
  rp.grantee
from information_schema.routine_privileges rp
join pg_proc p on p.proname = rp.routine_name::name
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'::name
  and rp.routine_schema::name = 'public'::name
  and rp.privilege_type::text = 'EXECUTE'::text
  and rp.grantee::name = any (array['anon'::name, 'authenticated'::name, 'PUBLIC'::name])
  and p.prosecdef = true
  and not (
    rp.grantee::name = 'authenticated'::name
    and rp.routine_name::name = any (array[
      'create_order'::name, 'accept_invite'::name, 'confirm_received'::name,
      'create_bundle'::name, 'create_company_and_admin'::name,
      'cancel_pending_order'::name
    ])
  );

revoke all on public.internal_function_grant_leaks from anon, authenticated, public;
grant select on public.internal_function_grant_leaks to service_role;
