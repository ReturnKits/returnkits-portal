-- Multi-parcel tracking: an order genuinely shipping as more than one box
-- (e.g. 2 outbound parcels, 2 return parcels) on the same leg. Direct user
-- request: "CAN I HAVE THE OPTION TO ADD ADDITIONAL TRACKING TO AN ORDER?" --
-- confirmed via two rounds of AskUserQuestion to mean genuine simultaneous
-- multi-parcel support, not tracking-number replacement/correction (which
-- already has a natural home in fulfilment_log/update_order_tracking).
--
-- Deliberately additive, not a redesign of the flat order model: the
-- existing outbound_*/return_* columns on orders stay exactly as they are
-- (the "primary" parcel per leg) -- this table only holds genuinely EXTRA
-- parcels. Each extra parcel gets its own independent status/status_log,
-- per the user's own scoping answer: "JUST ADD ADDITIONAL TRACKING IF MORE
-- THAN 1 TRAACKING NUMBER AS WELL AS ADDITIONA STATUS TIMELINE IF MORE THAN
-- 1". Order-level fulfilment_status/auto-complete stays keyed off the
-- primary parcel only in this v1 -- extending that to "all parcels
-- delivered" vs "any one" is an unconfirmed design fork, deliberately left
-- out rather than risked against the already-live, already-tested core
-- Sendcloud state machine.

create table public.order_tracking_numbers (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  leg text not null check (leg in ('outbound', 'return')),
  courier text,
  tracking_number text not null,
  tracking_url text,
  status text not null default 'awaiting_scan' check (status in ('awaiting_scan', 'in_transit', 'delivered')),
  status_log jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid references public.users(id)
);

create index order_tracking_numbers_order_id_idx on public.order_tracking_numbers (order_id);
create index order_tracking_numbers_tracking_number_idx on public.order_tracking_numbers (tracking_number);

alter table public.order_tracking_numbers enable row level security;

create policy order_tracking_numbers_select_own_company
on public.order_tracking_numbers for select
using (company_id = current_company());

revoke all on public.order_tracking_numbers from public, anon, authenticated;
grant select on public.order_tracking_numbers to authenticated;
grant select, insert, update, delete on public.order_tracking_numbers to service_role;

create or replace function public.add_order_tracking_number(
  p_order_id uuid, p_actor_id uuid, p_leg text, p_courier text,
  p_tracking_number text, p_tracking_url text default null
)
returns uuid
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_order public.orders%rowtype;
  v_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'add_order_tracking_number can only be called by the Retool write API';
  end if;
  perform public.assert_internal_actor(p_actor_id);
  if p_leg not in ('outbound', 'return') then
    raise exception 'Invalid leg: % (must be outbound or return)', p_leg;
  end if;
  if p_tracking_number is null or btrim(p_tracking_number) = '' then
    raise exception 'A tracking number is required';
  end if;
  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;
  if p_leg = 'return' and v_order.service_type <> 'return' then
    raise exception 'Order % has no return leg (service_type is %)', p_order_id, v_order.service_type;
  end if;
  insert into public.order_tracking_numbers (
    order_id, company_id, leg, courier, tracking_number, tracking_url, created_by
  )
  values (
    p_order_id, v_order.company_id, p_leg,
    nullif(btrim(p_courier), ''), btrim(p_tracking_number), nullif(btrim(p_tracking_url), ''),
    p_actor_id
  )
  returning id into v_id;
  perform public.log_audit(
    p_actor_id, 'order.add_tracking_number', 'order_tracking_numbers', v_id, null,
    (select to_jsonb(t) from public.order_tracking_numbers t where t.id = v_id)
  );
  return v_id;
end;
$function$;

revoke execute on function public.add_order_tracking_number from public, anon, authenticated;
grant execute on function public.add_order_tracking_number to service_role;

create or replace function public.remove_order_tracking_number(
  p_tracking_number_id uuid, p_actor_id uuid
)
returns void
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_row public.order_tracking_numbers%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'remove_order_tracking_number can only be called by the Retool write API';
  end if;
  perform public.assert_internal_actor(p_actor_id);
  select * into v_row from public.order_tracking_numbers where id = p_tracking_number_id;
  if not found then
    raise exception 'Tracking number row % not found', p_tracking_number_id;
  end if;
  delete from public.order_tracking_numbers where id = p_tracking_number_id;
  perform public.log_audit(
    p_actor_id, 'order.remove_tracking_number', 'order_tracking_numbers', p_tracking_number_id,
    to_jsonb(v_row), null
  );
end;
$function$;

revoke execute on function public.remove_order_tracking_number from public, anon, authenticated;
grant execute on function public.remove_order_tracking_number to service_role;
