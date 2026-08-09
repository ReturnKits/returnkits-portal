# Retool Ops Dashboard — Setup (Phase 4)

Companion to `returnkits-portal-architecture.md` §Ops dashboard and `returnkits-getting-started.md` Step 7. This is the concrete connection and build guide for the Retool app — written because I (Claude) have no Retool access; someone has to click through this by hand.

**Auth model (decided):** Retool uses one shared privileged connection for everything. There's no per-staff Supabase login. Accountability comes from an explicit "acting as" picklist in the UI, which every write function validates against real `internal_admin`/`internal_ops` rows via `assert_internal_actor()`. `auth.uid()` is meaningless here — a `service_role`-authenticated call carries no user claims — so don't look for it in `audit_log`; look at the `p_actor_id` you passed instead.

## 1. Two Retool resources, two different trust levels

### 1a. Postgres resource (reads only)

Project Settings → Database in the Supabase dashboard has the connection details (host, port, database, user, password — use the pooler connection, not direct, for Retool). I don't have this password; only you can retrieve or reset it from the dashboard.

**Important trust note:** the standard Postgres connection role is not subject to RLS the way `authenticated`/`anon` are — Retool's queries will see every company's rows regardless of tenant. That's expected and fine for an internal ops tool, but it means Retool itself is the only thing standing between an ops user and cross-tenant data, not RLS. Two consequences for how you build queries:

- Never build a Retool view that lets one company see another's orders as a *feature* — always filter explicitly (`where company_id = {{ select.value }}` etc.) even though the connection *could* return everything.
- Don't give Retool viewer/editor access to more staff than need it — it's the actual security boundary here, not a defense-in-depth layer.

Use this resource for: the order list/table, order detail lookups, the company/employee/kit_type dropdowns you'll need to populate forms, and the "acting as" staff picklist (query `select id, email from users where role in ('internal_admin','internal_ops') and status = 'active' order by email` — `users` has no name column, `email` is the only human-readable field on it).

### 1b. REST API resource (writes only)

Create a second resource, type **REST API**, base URL:

```
https://pzewknoohcqdqrrhwqrs.supabase.co
```

Headers (apply to every request on this resource):

```
apikey: <service_role key>
Authorization: Bearer <service_role key>
Content-Type: application/json
```

The `service_role` key is in Supabase Project Settings → API. Paste it directly into Retool's resource credential field (Retool encrypts resource credentials at rest) — never into a query body, never into a text/JS transformer where it'd be visible in query results or logs.

This key bypasses RLS entirely and can do anything to the database. It must only ever live in this one Retool resource config. Per CLAUDE.md rule #2, it must never reach the customer portal or any client bundle — Retool is the one place it's meant to be.

## 2. The four write endpoints

All four require the caller to already be authenticated as `service_role` (checked via `auth.role()` inside the functions, redundant with the fact that only `service_role` has EXECUTE at all) — a normal Retool REST query using the resource above satisfies this automatically.

**Gotcha:** the three RPCs and the Edge Function use different parameter-naming conventions. Don't copy-paste one query's body shape into another.

### `mark_order_dispatched` — PostgREST RPC

```
POST /rest/v1/rpc/mark_order_dispatched
```

Body (params are `p_`-prefixed, matching the SQL function signature exactly):

```json
{
  "p_order_id": "{{ orderTable.selectedRow.data.id }}",
  "p_actor_id": "{{ actingAsPicklist.value }}",
  "p_courier": "{{ courierInput.value }}",
  "p_tracking_number": "{{ trackingNumberInput.value }}",
  "p_tracking_url": "{{ trackingUrlInput.value }}"
}
```

`p_tracking_url` is optional (defaults to null) — fine to leave the input empty. Fails with a clear Postgres error if the order isn't in `awaiting_dispatch`, or if `p_actor_id` isn't a real internal user.

### `create_internal_order` — PostgREST RPC

```
POST /rest/v1/rpc/create_internal_order
```

Body:

```json
{
  "p_company_id": "{{ companySelect.value }}",
  "p_actor_id": "{{ actingAsPicklist.value }}",
  "p_kit_type_id": "{{ kitTypeSelect.value }}",
  "p_service_type": "{{ serviceTypeSelect.value }}",
  "p_employee_id": "{{ employeeSelect.value }}",
  "p_return_address_id": "{{ returnAddressSelect.value }}",
  "p_device_reference": "{{ deviceReferenceInput.value }}",
  "p_requested_send_date": "{{ sendDatePicker.formattedValue }}",
  "p_leaver_last_day": "{{ leaverLastDayPicker.formattedValue }}",
  "p_bundle_id": "{{ bundleIdInput.value }}",
  "p_order_reference": null
}
```

Leave `p_order_reference` as `null` unless you're deliberately overriding the atomic reference generator (you shouldn't need to). `p_service_type` is `'return'` or `'ship_to_new_employee'`.

**Gotcha, corrected from an earlier version of this doc:** `p_employee_id` is **always required, for both service types** — it identifies the employee the order is about (the leaver for a return, the new joiner for a ship-to-new-employee), not just the shipping recipient. This mirrors `create_order()` (the customer-facing path) exactly, including the same bug-shaped trap: passing `null` for `p_employee_id` raises "Employee not found for this company" regardless of service type. `p_return_address_id` is genuinely optional — only meaningful for return orders, and even then only if you want to override the company's default return address.

### `update_order_tracking` — PostgREST RPC (staff corrections, independent of dispatch state)

```
POST /rest/v1/rpc/update_order_tracking
```

Body — every field except the two IDs is optional; only pass what you're setting or correcting:

```json
{
  "p_order_id": "{{ orderTable.selectedRow.data.id }}",
  "p_actor_id": "{{ actingAsPicklist.value }}",
  "p_outbound_courier": "{{ outboundCourierInput.value }}",
  "p_outbound_tracking_number": "{{ outboundTrackingInput.value }}",
  "p_outbound_tracking_url": "{{ outboundTrackingUrlInput.value }}",
  "p_return_courier": "{{ returnCourierInput.value }}",
  "p_return_tracking_number": "{{ returnTrackingInput.value }}",
  "p_return_tracking_url": "{{ returnTrackingUrlInput.value }}"
}
```

Unlike `mark_order_dispatched` (a state-transition function — requires `awaiting_dispatch`, moves the order to `dispatched`), this one works regardless of `fulfilment_status` and never changes it. It exists for corrections: a mistyped tracking number, or a customer phoning in their return tracking number instead of using Confirm Sent in the portal. Every order has two independent tracking legs — `outbound_*` (what ReturnKits ships out) and `return_*` (the device coming back, return orders only) — and this is the one write path that can touch either without going through a status change. Fails if you call it with all seven optional fields empty (nothing to update).

### `generate-print-pack` — Edge Function (different base path, different body shape)

```
POST /functions/v1/generate-print-pack
```

This is **not** under `/rest/v1/rpc/` — it's a separate Edge Function with its own auth check (`Authorization` header must equal `Bearer <service_role key>` exactly; the `apikey` header isn't required here but doesn't hurt to leave it, since it's set at the resource level).

Body uses camelCase, not `p_`-prefixed snake_case:

```json
{
  "orderId": "{{ orderTable.selectedRow.data.id }}",
  "actorId": "{{ actingAsPicklist.value }}"
}
```

Returns `{ "url": "<signed URL, valid 1 hour>", "storagePath": "...", "expiresInSeconds": 3600 }`. Wire the button's success handler to open `{{ generatePrintPack.data.url }}` in a new tab (Retool: "Open URL" action on query success).

## 3. What to build

A complete ops app needs six things:

**Order list.** A Postgres-backed table, default sorted newest first. Filters on `fulfilment_status`, `service_type`, `company_id`, and a date range on `created_at`. Surface `reference`, `company`, `kit_type`, `service_type`, `fulfilment_status`, `outbound_courier`/`outbound_tracking_number`, `return_courier`/`return_tracking_number`, `created_at` as columns — both tracking legs, not just outbound, since return orders' return leg is just as important to see at a glance. Clicking a row selects it for the action panel below.

**Acting-as picklist.** One select, populated from the `internal_admin`/`internal_ops` query above, pinned somewhere always-visible (top of the page, not per-form) since every write needs it. Consider persisting the last-used value in Retool's local storage so staff don't re-pick it every session.

**Dispatch panel.** Visible when the selected order's `fulfilment_status = 'awaiting_dispatch'`. Courier text input, tracking number input, optional tracking URL input, a "Mark dispatched" button wired to the `mark_order_dispatched` query. On success, refresh the order table query.

**Tracking correction panel.** Separate from the dispatch panel — available on any selected order regardless of status. Outbound courier/tracking/URL inputs and return courier/tracking/URL inputs, each pre-filled with the order's current values, a "Save tracking" button wired to `update_order_tracking`. Only send the fields that actually changed (or just send all six every time — the function coalesces against existing values either way, so re-sending unchanged values is harmless).

**Manual order form.** A modal or separate tab: company select, kit type select, service type radio, an employee select (**always required, for both service types** — see the gotcha above), a return-address select (optional, return orders), device reference, send date / leaver last day date pickers, optional bundle ID. Submit wired to `create_internal_order`. On success, show the returned reference and refresh the order table.

**Print Pack button.** On the order detail panel (or as a table row action), calls `generate-print-pack` and opens the signed URL. Useful on any order regardless of status, but most relevant once dispatched.

Not in scope for Phase 4 (per the implementation plan — don't build ahead): Sendcloud label purchase automation (Phase 6, still manual in Sendcloud's own dashboard) — `update_order_tracking` is a manual stand-in for what Phase 6's tracking webhooks will eventually do automatically. Also out of scope here: Confirm Sent/Received (that's the customer, in Lovable, not staff in Retool), credits/promo, bulk CSV ordering.

## 4. Verifying it works (Phase 4 exit criteria)

Once the app above exists, walk through this live:

1. Place a test order as a customer (Lovable), pay it through Stripe test mode as in Phase 3 — status should land on `awaiting_dispatch`.
2. In Retool, select that order, pick yourself in the acting-as list, fill in a fake courier/tracking number, hit Mark dispatched. Confirm the order table refreshes and shows `dispatched`.
3. Reload the order in Lovable as the customer — the status timeline should show "Dispatched" with the tracking number, and (if it's a return order) a "Confirm sent" button should appear.
4. Click Print Pack in Retool — confirm a PDF opens with the right order reference, company, and address block.
5. Run this SQL (via `execute_sql` or the Supabase SQL editor) to confirm the write was attributed correctly:
   ```sql
   select action, actor_id, created_at from audit_log
   where target_id = '<order id>' order by created_at;
   ```
   `actor_id` should be the internal user you picked in the acting-as list, not null and not some service-role placeholder.
6. As the customer, click Confirm sent/received in Lovable and confirm the order reaches `confirmed_sent`/`completed`, and that a corresponding `audit_log` row appears with `actor_id` = the *customer's* `auth.uid()` (different code path — real user JWT, not the shared credential).

If any step fails, the SQL side (RPCs, RLS, `assert_internal_actor`) is already covered by `tests/rls.test.ts` — the most likely failure point is a Retool query wiring mistake (wrong param names, missing header), not the backend.
