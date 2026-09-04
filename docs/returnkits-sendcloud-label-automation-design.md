# ReturnKits — Sendcloud Label Purchase Automation (Design Only)

**Status: design, not built.** Nothing in this doc has been applied to the database, deployed, or connected to a real Sendcloud account. Written 20260821 at the user's request for a design-first pass before any code or migration is touched — see the "no automated refunds," "review every migration," and "do not build ahead" conventions already established in `CLAUDE.md`.

Supersedes/updates §7 of `returnkits-portal-architecture.md` ("Shipping Automation (Carrier Integration)"), which was written pre-build and assumed EasyPost, rate shopping across multiple carriers, and a `ShippingProvider` abstraction. None of that was built. What actually shipped in Phase 6 (20260811) was Sendcloud, tracking-only, with labels bought manually in Sendcloud's own dashboard — a deliberate, explicitly confirmed decision at the time ("I will do labels manually but we need tracking in the portal"). This doc is about reversing that one decision, now that the Royal Mail return model needs a return label to exist *before* the outbound parcel ships, not after.

## 1. Why this is being revisited now

The old return flow (courier collection, arranged by staff) never needed a pre-existing return label — a courier just turned up and took the device. The new Royal Mail model (§ CLAUDE.md, "UK return model overhauled," 20260821) puts a **prepaid return label inside the box at the point of dispatch**. That label has to exist before the outbound parcel is packed. Manually buying it in Sendcloud's dashboard still works, but it adds a real step to what used to be "look up the outbound label, print it" — staff now also has to separately create and print a return label per return-service order, get the timing right, and physically get it in the box. That's the actual gap this design addresses, not "labels are annoying to buy."

## 2. What's actually true today (verified against the live project, not assumed)

- `kit_types` has no weight or dimension columns. Any parcel API call needs both.
- `orders` has `outbound_courier`/`outbound_tracking_number`/`outbound_tracking_url` and the matching `return_*` columns, but nothing for a Sendcloud parcel ID or a stored label file URL.
- Sendcloud credentials already exist in Vault and are already used by `poll-sendcloud-tracking` via `get_sendcloud_api_credentials()` — both the public and secret key, for HTTP Basic Auth against the **v2** REST API (`https://panel.sendcloud.sc/api/v2/...`).
- The existing Sendcloud integration in this codebase (webhook + poll fallback + scheduled poll) is **v2 throughout**, chosen deliberately because Sendcloud documents v2 as "maintenance mode but fully functional," not because v3 was evaluated and rejected.
- `sendcloud_status_map`, `sendcloud_poll_status_map`, and `sendcloud_carrier_map` are all hardened, RLS-locked, `service_role`-only lookup tables seeded from real observed traffic. The label-purchase work would not touch any of these — it's a separate concern (buying a label vs. tracking one that already exists).
- The `ShippingProvider` interface described in the original architecture doc (`validateAddress`, `getRates`, `buyLabel`, `voidLabel`, `bookPickup`, `parseTrackingWebhook`) was never built. Every Sendcloud touchpoint that exists today (webhook handler, poll functions) calls Sendcloud's REST API directly from a Supabase Edge Function, with no abstraction layer in between.

## 3. Decisions that need a real answer before any code is written

### 3.1 API version: v2 or v3

Sendcloud's v2 "Create a parcel" endpoint (`POST /api/v2/parcels`) supports creating a parcel object and, in the same call, requesting a label (`request_label: true`) if a shipping method ID is already known — or as a follow-up `PUT` once one's been chosen. It uses the same Basic Auth key pair already in Vault. Sendcloud's v3 has purpose-built `Shipments`, `Orders`, and a one-call `Ship an Order` API, and is what Sendcloud recommends for anything new — but this project has not confirmed whether v3 uses the same Basic Auth credentials or a different auth scheme (OAuth 2.0 is common on newer Sendcloud v3 endpoints elsewhere in their docs; this needs a direct check, not an assumption, before it's relied on).

**Recommendation:** start on v2. It reuses the exact credential and error-handling pattern already proven in `poll-sendcloud-tracking`, it's confirmed to still work, and label purchase is a much smaller, more contained call than the ongoing tracking-poll relationship — not worth introducing a second auth scheme into the codebase for. Revisit v3 later only if v2's label endpoints show a real limitation (e.g. multi-collo, which this project doesn't need — ReturnKits ships one box per order).

### 3.2 Fixed shipping method vs. rate shopping

The original architecture doc assumed rate shopping across multiple carriers. That's no longer the shape of the business — Royal Mail is now the sole carrier for both legs, and each kit type ships in a fixed, known box. There's nothing to shop for.

**Recommendation:** hardcode one Sendcloud `shipping_method` ID per kit type (Laptop/Phone/Monitor), fetched once via `GET /api/v2/shipping_methods` and stored as a plain config value (a new small lookup table, or a column on `kit_types` — see §4). No live rate call on the order-creation path at all. This also sidesteps the entire "rate shopping" scope that was explicitly deferred in the Phase 6 build.

### 3.3 Does this need the `ShippingProvider` abstraction the architecture doc called for?

Real tension worth naming rather than quietly deciding: the original design wanted an interface from day one specifically so a carrier swap wouldn't touch order flow, webhooks, and fulfillment UI all at once. Nothing since has followed that pattern — every Sendcloud call in the live codebase is a direct fetch to Sendcloud's API from inside an Edge Function, with normalization happening at the point of use (e.g. `sendcloud_status_map`) rather than behind a formal interface.

**Recommendation:** stay consistent with what's actually been built rather than retrofit an abstraction now. ReturnKits is single-carrier by explicit business decision (Royal Mail), and the cost of an interface is paid to make a future carrier swap cheap — a swap that isn't currently anticipated. Building one now would be scope this project has repeatedly and deliberately avoided elsewhere ("smallest defensible v1"). Flagging this as a deliberate call, not an oversight, since it does contradict the original architecture doc — worth a one-line sign-off before building either way.

## 4. Schema changes this would need

All additive, all matching existing naming conventions in this project (snake_case, `outbound_`/`return_` leg prefixes, nullable, no destructive change to anything live).

- `kit_types`: `weight_grams integer`, `length_mm integer`, `width_mm integer`, `height_mm integer`, `sendcloud_shipping_method_id integer` — one fixed shipping method per kit type, populated once staff confirms the real Royal Mail service/contract in Sendcloud's dashboard. All nullable until populated, so this ships without breaking anything, and label purchase for a kit type simply isn't attempted until its row is filled in.
- `orders`: `outbound_sendcloud_parcel_id integer`, `outbound_label_url text`, `return_sendcloud_parcel_id integer`, `return_label_url text` — mirrors the existing `outbound_*`/`return_*` tracking-column split exactly, so every downstream reader that already knows how to pick "whichever leg is active" (CSV export, Retool panel, `generate-print-pack`) extends the same way it already does for courier/tracking.
- No changes to `sendcloud_status_map`, `sendcloud_poll_status_map`, `sendcloud_carrier_map`, or any tracking RPC — those stay exactly as they are; label purchase and tracking are genuinely separate concerns that happen to share a vendor.

## 5. Sequencing — when do labels actually get bought

This is the part the old "buy it when convenient" mental model doesn't fit anymore. Proposed sequence for a **return** order (the case that actually needs this):

1. Order is paid (`payment_status = 'paid'`) — same gate `mark_order_dispatched` already enforces.
2. **Before** dispatch, a new step buys **both** labels in one pass: the outbound delivery label (to the employee) and the prepaid return label (`is_return: true`, `from_*` = the employee's address, matching the box they're about to receive) — same order, same trigger, because the return label has to be printed and physically included in that same box.
3. Both label PDFs get attached to (or merged into) the Print Pack staff already generate, so "print the pack" produces everything needed in one document — outbound label, return label, and the existing packing/instruction sheet — rather than three separate manual downloads.
4. Staff pack and dispatch as today; `mark_order_dispatched` fires as it already does.

For a **ship-to-new-employee** order, there's no return label at all — this only ever buys the single outbound label, same as before.

**Trigger point recommendation:** a staff-initiated step in Retool ("Buy labels" button, same shape as "Check Tracking Now" and "Mark as paid"), not fully automatic on payment. Reasoning: address problems, weight mismatches, or a Sendcloud account issue should surface to a human before real money is spent and before a customer is told their kit shipped — this project's own "no automated refunds, cancellation is admin-only" posture suggests the same caution applies here. A fully automatic version is a reasonable v2 once the manual version has run cleanly for a while.

## 6. New Edge Function

`buy-shipping-labels` (name open to bikeshedding), same shape and hardening as `poll-sendcloud-tracking`:

- `verify_jwt: false`; the function checks the `Authorization` bearer against `SUPABASE_SERVICE_ROLE_KEY` itself, matching every other Retool-triggered write in this codebase.
- Input: `order_id`, real `actor_id` (staff-triggered, so — unlike the scheduled tracking poll — this always has a human behind it and should log one, same `assert_internal_actor` pattern `apply_sendcloud_poll_result` already uses).
- Looks up the order's kit type, resolves weight/dimensions/shipping method from `kit_types`, resolves the employee/return addresses via the existing `resolveEmployee()`-style helper already shared by `send-order-email` and `generate-print-pack` (reuse, don't reinvent).
- Calls Sendcloud's create-parcel-with-label endpoint once for the outbound leg, and — for return orders — once more with `is_return: true` for the return leg.
- Writes the parcel ID and label URL back onto the order via a new RPC (`record_shipping_labels` or similar, `service_role`-only, same grant-hardening discipline as every other internal RPC in this project — explicit `revoke ... from public, anon, authenticated` from the start, learned the hard way five times already in this project's history).
- Idempotent: if `outbound_sendcloud_parcel_id`/`return_sendcloud_parcel_id` are already set, a repeat call is a no-op rather than buying a second label and double-charging.
- Errors (bad address, unsupported postcode, Sendcloud account issue) come back as a normal failure response with Sendcloud's own message passed through — Retool shows it, staff fixes the underlying data (e.g. a bad manually-entered address) and retries, rather than the function guessing at a fix.

## 7. Cost and testing

Sendcloud invoices for every real label bought unless the shipping method used is their dedicated **test method ("Unstamped letter," id `8`)**, which produces a real-shaped label but never actually charges or ships. The build-and-test phase should run entirely against that test method first — same discipline this project already used for the tracking-poll feature (live-tested against a real order before trusting it). Only once the function's request/response handling is proven should it be pointed at the real Royal Mail shipping method ID and left to spend real money.

## 8. Rollout, in order

1. Confirm Royal Mail is connected in the Sendcloud dashboard as an actual carrier contract/integration (not just used manually) — this is an account-configuration step, not code.
2. Pull the real Royal Mail `shipping_method` ID(s) via `GET /api/v2/shipping_methods` and get real weight/dimensions for each kit type's physical box.
3. Confirm v2 vs v3 auth (§3.1) with a single throwaway API call before committing either way.
4. Write and apply the `kit_types`/`orders` migration (§4) — additive, no risk to anything live.
5. Build `buy-shipping-labels` against the free test shipping method only.
6. Wire the Retool "Buy labels" button + status/retry surface.
7. Extend `generate-print-pack` to pull in both label PDFs.
8. One real live test against a real order, same pattern as the original tracking-poll live test (a genuine parcel, watched end to end) — before this touches normal order volume.
9. Update `CLAUDE.md` with the resulting locked decision once it's actually live, same as every other feature in this project's history.

## 9. Open questions for the user

- Confirm the "buy both labels together, staff-triggered, before pack" sequencing in §5 is right — or whether outbound-only-on-payment + return-on-a-separate-trigger is closer to how packing actually happens day to day.
- Confirm the "no `ShippingProvider` abstraction, single-carrier, direct Sendcloud calls" call in §3.3 — this is the one place this design deliberately diverges from the original architecture doc.
- Real weight/dimensions per kit type box — needed before step 2 above can happen at all.
- Whether label cost should show up anywhere in the portal/Retool (e.g. an actual Royal Mail invoice cost visible to staff) or stays purely a Sendcloud-account-level cost with no portal visibility, consistent with how Enhanced Cover declared-value passthrough is already handled.
