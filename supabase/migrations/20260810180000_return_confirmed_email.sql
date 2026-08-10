-- ============================================================================
-- return_confirmed email: closes the loop for return orders once
-- confirm_sent fires (fulfilment_status -> 'confirmed_sent'). Prompted by a
-- gap found against the Base44 reference design's "Return Confirmed" email --
-- previously the orderer heard nothing between the dispatch email and the
-- next scheduled check-in nudge, which could be days later.
--
-- Same trigger pattern as trigger_send_order_email's existing callers
-- (on_order_paid_send_confirmation, on_order_dispatched_send_email) from
-- 20260809161000_phase5_email_triggers.sql -- fire-and-forget via pg_net so
-- confirm_sent itself never blocks or fails on an email problem.
--
-- ship_to_new_employee orders reach 'completed' via confirm_received with no
-- equivalent closing email yet. Deliberately not added here -- smaller,
-- symmetric gap, left for a follow-up so this migration stays scoped to the
-- one thing that was actually asked for.
-- ============================================================================

alter table public.communication_log drop constraint communication_log_type_check;
alter table public.communication_log add constraint communication_log_type_check
  check (type in ('order_confirmation', 'dispatched', 'return_confirmed', 'checkin_sent', 'checkin_received'));

alter table public.notification_preferences drop constraint notification_preferences_event_type_check;
alter table public.notification_preferences add constraint notification_preferences_event_type_check
  check (event_type in ('order_confirmation', 'dispatched', 'return_confirmed', 'checkin_sent', 'checkin_received'));

-- New companies get the row via the existing seed trigger going forward.
create or replace function public.seed_default_notification_preferences()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notification_preferences (company_id, event_type, enabled)
  select new.id, event_type, true
  from unnest(array['order_confirmation', 'dispatched', 'return_confirmed', 'checkin_sent', 'checkin_received']) as event_type
  on conflict (company_id, event_type) do nothing;
  return new;
end;
$$;

-- Existing companies (created before this migration) need the row backfilled
-- explicitly -- the seed trigger only fires on company insert.
insert into public.notification_preferences (company_id, event_type, enabled)
select id, 'return_confirmed', true from public.companies
on conflict (company_id, event_type) do nothing;

create or replace function public.on_order_return_confirmed_send_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.fulfilment_status = 'confirmed_sent' and (old.fulfilment_status is distinct from 'confirmed_sent') then
    perform public.trigger_send_order_email(new.id, 'return_confirmed');
  end if;
  return new;
end;
$$;

create trigger trg_order_return_confirmed_send_email
  after update on public.orders
  for each row execute function public.on_order_return_confirmed_send_email();
