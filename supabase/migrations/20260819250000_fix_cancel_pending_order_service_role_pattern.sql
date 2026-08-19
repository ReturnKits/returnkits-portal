-- supabase/migrations/20260819250000_fix_cancel_pending_order_service_role_pattern.sql
--
-- Same-day fix for cancel_pending_order() (20260819240000), caught by a
-- live verification run against the hosted database before this was ever
-- wired up in Lovable -- same "live-test before going near the UI"
-- discipline as the Check Tracking Now / credit-cover-checkout features.
--
-- The bug: cancel_pending_order() was written as a plain `authenticated`-
-- callable RPC (auth.uid() derives the caller, same shape as create_order),
-- but there is a trigger on public.orders -- enforce_orders_payment_fields_
-- immutable_by_client() -- that raises unconditionally whenever
-- payment_status changes and auth.role() is not 'service_role':
--   "payment_status and invoice_id can only be set by the Stripe webhook
--   handler"
-- This trigger predates this feature and was never mentioned when
-- cancel_pending_order was designed -- it exists to stop any client-role
-- session from forging a paid/cancelled state directly. cancel_order()
-- (staff-only) has always been fine because Retool's write API calls it as
-- service_role; a plain customer session calling a function that ultimately
-- runs `update ... set payment_status = 'cancelled'` as role 'authenticated'
-- hits this trigger every time, live-confirmed:
--   ERROR: payment_status and invoice_id can only be set by the Stripe
--   webhook handler
--
-- This migration does NOT loosen that trigger -- it is a deliberate,
-- correct invariant (payment_status must never be settable by an ordinary
-- client session) and loosening it for this one feature would reopen
-- exactly the kind of tampering surface it exists to close. Instead,
-- cancel_pending_order is rebuilt on the SAME auth shape as cancel_order:
-- service_role-only, called from a new Edge Function
-- (cancel-pending-order) that verifies the caller's own JWT, then invokes
-- this RPC with the service_role key -- identical to how every Stripe
-- checkout Edge Function in this project already escalates to service_role
-- for exactly the operations that need it, while still being reachable by
-- an ordinary signed-in customer.
--
-- Since the RPC now runs as service_role, it can no longer trust
-- auth.uid()/current_company()/current_role() (those read JWT claims that
-- belong to whichever key made the underlying connection -- meaningless
-- once that's the service_role key). The caller's identity is now passed
-- explicitly as p_actor_id (same as cancel_order's own p_actor_id) and the
-- function looks up that user's own company_id/role from public.users
-- directly -- service_role can read any row, so this is a safe, correct
-- substitute for the JWT claims a real authenticated session would have
-- carried.

-- Drop the old (uuid, text) signature -- different arg list to the
-- replacement below, so `create or replace` would leave both live as
-- separate overloads (the exact PGRST203 bug class already fixed once in
-- this project, 20260813160000). Drop it explicitly rather than relying on
-- create or replace alone.
drop function if exists public.cancel_pending_order(uuid, text);

create or replace function public.cancel_pending_order(
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
  v_actor public.users%rowtype;
  v_before jsonb;
  v_log_entry jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'cancel_pending_order can only be called via the cancel-pending-order edge function';
  end if;

  select * into v_actor from public.users where id = p_actor_id;
  if not found then
    raise exception 'Actor not found';
  end if;

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order not found';
  end if;

  -- Don't leak whether an order exists in another company -- same "not
  -- found" wording whether it's genuinely missing or just not this actor's.
  if not (
    v_actor.role in ('internal_admin', 'internal_ops')
    or v_order.company_id = v_actor.company_id
  ) then
    raise exception 'Order not found';
  end if;

  if not (
    v_actor.role in ('internal_admin', 'internal_ops')
    or v_actor.role = 'company_admin'
    or v_order.created_by = p_actor_id
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
    'actor_id', p_actor_id,
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
    p_actor_id, 'order.cancel_pending', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$$;

-- Same service_role-only pattern as cancel_order, mark_order_paid, etc. --
-- revoke from PUBLIC explicitly too (20260819120000's lesson), not just
-- anon/authenticated by name.
revoke all on function public.cancel_pending_order(uuid, uuid, text) from public;
revoke execute on function public.cancel_pending_order(uuid, uuid, text) from anon, authenticated;

-- Remove cancel_pending_order from internal_function_grant_leaks' allowlist
-- -- it no longer needs one. The prior migration (20260819240000) added it
-- there on the assumption 'authenticated' would stay granted; now that it's
-- service_role-only like cancel_order, leaving it in the allowlist would
-- wrongly excuse a REAL future leak if 'authenticated' were ever granted to
-- it by mistake. Same drop+recreate shape as every prior edit to this view.
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
      'create_bundle'::name, 'create_company_and_admin'::name
    ])
  );

revoke all on public.internal_function_grant_leaks from anon, authenticated, public;
grant select on public.internal_function_grant_leaks to service_role;
