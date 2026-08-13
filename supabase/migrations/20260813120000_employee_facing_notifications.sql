-- Employee-facing passive notifications (20260813).
--
-- The user wants a "kit is on its way" notice and the "please send it back"
-- return nudges to also reach the employee directly -- but with no order
-- details (no pricing, no reference, no invoice info), and the nudges must
-- stop the moment we know the device is on its way back.
--
-- Deliberately reuses the existing type vocabulary ('dispatched',
-- 'checkin_sent') rather than inventing new ones: this IS the same event,
-- just a second, stripped-down recipient. Reusing the type means it's
-- automatically covered by the existing notification_preferences toggle (if
-- a company mutes 'dispatched', the employee copy is muted too -- one
-- switch, not two) and, for checkin_sent specifically, automatically
-- inherits orders_needing_checkin()'s existing stopping condition: that
-- function only selects orders still sitting in fulfilment_status =
-- 'dispatched', so the moment a return tracking scan flips the order to
-- 'in_transit' (apply_sendcloud_tracking_event), the order drops out of the
-- eligibility query entirely and no further employee reminders go out --
-- exactly "stop when we know it's on its way back", with zero new logic.
--
-- No new preference row, no new cron job, no new eligibility SQL. The only
-- schema change needed is widening this CHECK constraint -- the rendering
-- and sending logic lives entirely in send-order-email (Edge Function),
-- same file, same auth model, same suppression-list gate as the existing
-- customer-facing sends.
--
-- Not extended to checkin_received (ship-to-new-employee "has it arrived"
-- nudge) or order_confirmation -- out of scope per what was actually asked
-- (return-leg nudges specifically), and order_confirmation would be
-- premature/inaccurate for an employee framing anyway since nothing
-- physical has moved yet at that point.
alter table public.communication_log drop constraint communication_log_audience_check;
alter table public.communication_log add constraint communication_log_audience_check
  check (audience in ('customer', 'internal', 'employee'));

comment on column public.communication_log.audience is
  'customer = the portal user who placed the order (orders.created_by). employee = the recipient on file (orders.employee_id -> employees.email), added 20260813 for passive dispatched/checkin_sent notices with no order/pricing detail -- never used for order_confirmation. internal = staff-facing.';
