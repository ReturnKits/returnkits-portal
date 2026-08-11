-- ============================================================================
-- Remove confirm_sent: customer self-reporting "I've posted the device back"
-- turned out to be more trust than the flow should carry -- we have no way
-- to verify it, and it silently blocked the check-in nudge from firing
-- (orders sitting in 'confirmed_sent' were excluded from
-- orders_needing_checkin(), which only chases 'dispatched' orders).
--
-- Decision: return orders now stay in 'dispatched' until we have a
-- definitive signal. Until the Sendcloud tracking integration lands
-- (deferred, CLAUDE.md build order) and can flip an order to 'completed'
-- off a real courier scan, the only signal is physical receipt -- so
-- orders_needing_checkin() keeps nudging every 3 days indefinitely, which is
-- the desired behaviour now, not a gap: reminders to send it back keep going
-- out until it's actually confirmed sent by tracking.
--
-- This also retires the return_confirmed email added in
-- 20260810180000_return_confirmed_email.sql -- it only ever fired off
-- fulfilment_status -> 'confirmed_sent', which no longer happens.
--
-- confirm_received (ship-to-new-employee) is unaffected and stays exactly
-- as it was -- that flow has a real, verifiable endpoint (the new starter
-- has the kit in hand) and isn't in question here.
-- ============================================================================

-- ---- Undo return_confirmed email -------------------------------------------

drop trigger if exists trg_order_return_confirmed_send_email on public.orders;
drop function if exists public.on_order_return_confirmed_send_email();

delete from public.notification_preferences where event_type = 'return_confirmed';

-- The one return_confirmed row in communication_log is this session's own
-- verification test send (RKM-260810-001, to ollie@beeseenlabs.com) -- not
-- a real customer notification, so deleting it rather than widening the
-- constraint to keep it around forever.
delete from public.communication_log where type = 'return_confirmed';

alter table public.communication_log drop constraint communication_log_type_check;
alter table public.communication_log add constraint communication_log_type_check
  check (type in ('order_confirmation', 'dispatched', 'checkin_sent', 'checkin_received'));

alter table public.notification_preferences drop constraint notification_preferences_event_type_check;
alter table public.notification_preferences add constraint notification_preferences_event_type_check
  check (event_type in ('order_confirmation', 'dispatched', 'checkin_sent', 'checkin_received'));

create or replace function public.seed_default_notification_preferences()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notification_preferences (company_id, event_type, enabled)
  select new.id, event_type, true
  from unnest(array['order_confirmation', 'dispatched', 'checkin_sent', 'checkin_received']) as event_type
  on conflict (company_id, event_type) do nothing;
  return new;
end;
$$;

-- ---- Remove confirm_sent ----------------------------------------------------

-- Any order currently sitting in 'confirmed_sent' loses that signal -- it
-- was self-reported and unverifiable, so the honest thing is to treat it the
-- same as every other in-flight return: back to 'dispatched', eligible for
-- check-in nudges again. Two rows affected as of this migration
-- (RKL-260807-001, RKM-260810-001), both from Phase 4/5 testing, not real
-- customer orders.
update public.orders
set fulfilment_status = 'dispatched',
    confirmed_sent_at = null,
    confirmed_sent_by = null
where fulfilment_status = 'confirmed_sent';

drop function if exists public.confirm_sent(uuid, text);

alter table public.orders drop constraint orders_fulfilment_status_check;
alter table public.orders add constraint orders_fulfilment_status_check
  check (fulfilment_status in ('awaiting_dispatch', 'dispatched', 'delivered', 'confirmed_received', 'completed', 'cancelled'));

comment on column public.orders.confirmed_sent_at is
  'Unused since confirm_sent was removed (20260811090000). Kept rather than dropped -- historical rows still carry values from when the flow existed, and dropping the column would lose that audit trail for no operational benefit.';
comment on column public.orders.confirmed_sent_by is
  'Unused since confirm_sent was removed (20260811090000). See confirmed_sent_at.';

-- orders_needing_checkin()'s doc comment (20260809172000) named confirm_sent
-- as the thing return orders were awaiting -- no longer accurate.
comment on function public.orders_needing_checkin() is
  'Orders due a check-in nudge right now: dispatched >= 5 working days ago, still sitting in ''dispatched'' (returns awaiting physical receipt, ship-to-new-employee awaiting confirm_received), and not nudged in the last 3 calendar days. Called by the send-checkin-notifications Edge Function on its pg_cron schedule.';
