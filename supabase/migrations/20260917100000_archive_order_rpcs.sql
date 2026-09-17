-- Archive / unarchive orders (staff-only, Retool).
-- Scope confirmed with the user: archive only (never hard delete -- consistent with
-- "cancelled invoices are voided, never deleted"), and only orders that are already
-- in a terminal fulfilment_status (completed or cancelled) can be archived.

alter table public.orders
  add column archived_at timestamptz null,
  add column archived_by uuid null references public.users(id);

alter table public.orders
  add constraint orders_archived_only_when_terminal
  check (archived_at is null or fulfilment_status in ('completed', 'cancelled'));

create or replace function public.archive_order(p_order_id uuid, p_actor_id uuid)
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
    raise exception 'archive_order can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if v_order.archived_at is not null then
    raise exception 'Order % is already archived', p_order_id;
  end if;

  if v_order.fulfilment_status not in ('completed', 'cancelled') then
    raise exception 'Order % cannot be archived (fulfilment_status: %) -- only completed or cancelled orders can be archived', p_order_id, v_order.fulfilment_status;
  end if;

  v_before := to_jsonb(v_order);

  update public.orders
  set archived_at = now(),
      archived_by = p_actor_id
  where id = p_order_id;

  perform public.log_audit(
    p_actor_id, 'order.archive', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$function$;

create or replace function public.unarchive_order(p_order_id uuid, p_actor_id uuid)
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
    raise exception 'unarchive_order can only be called by the Retool write API';
  end if;

  perform public.assert_internal_actor(p_actor_id);

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if v_order.archived_at is null then
    raise exception 'Order % is not archived', p_order_id;
  end if;

  v_before := to_jsonb(v_order);

  update public.orders
  set archived_at = null,
      archived_by = null
  where id = p_order_id;

  perform public.log_audit(
    p_actor_id, 'order.unarchive', 'orders', p_order_id, v_before,
    (select to_jsonb(o) from public.orders o where o.id = p_order_id)
  );
end;
$function$;

revoke all on function public.archive_order(uuid, uuid) from public, anon, authenticated;
grant execute on function public.archive_order(uuid, uuid) to service_role;

revoke all on function public.unarchive_order(uuid, uuid) from public, anon, authenticated;
grant execute on function public.unarchive_order(uuid, uuid) to service_role;
