-- Extending sendcloud_poll_status_map with real observed values, per the
-- table's own "extend from observed traffic" note. Live-tested 2026-08-13
-- against a real, genuinely-delivered Royal Mail parcel (MZ531042790GB) via
-- Sendcloud's v2 GET /tracking/{number} using pg_net, to confirm the poll
-- integration before wiring it into Retool. Three parent_status values
-- showed up that the doc-example-only seed didn't have: 'no-label' (before
-- a label even exists on Sendcloud's side), 'announced' (carrier notified,
-- distinct from Sendcloud's own 'announcing' pre-step), and
-- 'driver-on-route' (final-mile out-for-delivery equivalent -- clearly
-- still in transit, not yet delivered).
insert into public.sendcloud_poll_status_map (parent_status, normalized_status, notes) values
  ('no-label', 'ignored', 'Observed 2026-08-13 against a real delivered parcel (MZ531042790GB) -- pre-label, no fulfilment_status slot for this'),
  ('announced', 'ignored', 'Observed 2026-08-13 against a real delivered parcel (MZ531042790GB) -- carrier notified but not yet moving, distinct from Sendcloud''s own announcing step'),
  ('driver-on-route', 'in_transit', 'Observed 2026-08-13 against a real delivered parcel (MZ531042790GB) -- final-mile delivery attempt, still in transit')
on conflict (parent_status) do nothing;

-- Also correct sendcloud_poll_status_map's existing rows' notes now that
-- shipment-on-route and delivered are genuinely confirmed (not just from
-- the docs example) against this same real payload.
update public.sendcloud_poll_status_map
set notes = 'Confirmed 2026-08-13 against a real delivered parcel (MZ531042790GB), in addition to the original Sendcloud v2 tracking API OpenAPI example'
where parent_status in ('shipment-on-route', 'delivered', 'announcing', 'ready-to-send');
