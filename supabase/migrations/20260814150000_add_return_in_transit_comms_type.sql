-- Add 'return_in_transit' as a new communication_log/notification_preferences
-- event type: fires when a return-service order's fulfilment_status moves
-- dispatched -> in_transit (the courier's first scan on the return leg),
-- telling the ordering customer their return is on its way back, with an
-- estimated arrival date sourced from Sendcloud's expected_delivery_date
-- field when present (confirmed present in a real v2 tracking-poll payload
-- 20260814 -- top-level field on the tracking response, e.g.
-- "expected_delivery_date": "2026-07-30"; note the real parcel in that same
-- payload actually delivered a day later, so this is a carrier estimate,
-- not a guarantee -- copy should read that way), falling back to a
-- working-day estimate when the field is absent (not yet empirically
-- confirmed present on the webhook payload specifically, since zero real
-- webhooks have ever been received -- Sendcloud's own docs say the webhook
-- payload matches the parcel-retrieval payload shape, so it's expected to
-- carry the same field, but code reads it defensively either way).
-- Scoped to return-service orders only -- ship_to_new_employee orders have
-- no return leg. See CLAUDE.md for full design.

alter table public.communication_log
  drop constraint communication_log_type_check;

alter table public.communication_log
  add constraint communication_log_type_check
  check (type = any (array['order_confirmation', 'dispatched', 'checkin_sent', 'checkin_received', 'return_in_transit']));

alter table public.notification_preferences
  drop constraint notification_preferences_event_type_check;

alter table public.notification_preferences
  add constraint notification_preferences_event_type_check
  check (event_type = any (array['order_confirmation', 'dispatched', 'checkin_sent', 'checkin_received', 'return_in_transit']));
