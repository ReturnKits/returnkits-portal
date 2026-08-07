# Retool Ops Dashboard — Setup (Phase 4)

Companion to `returnkits-portal-architecture.md` §Ops dashboard and `returnkits-getting-started.md` Step 7. This is the concrete connection and build guide for the Retool app — written because I (Claude) have no Retool access; someone has to click through this by hand.

**Auth model (decided):** Retool uses one shared privileged connection for everything. There's no per-staff Supabase login. Accountability comes from an explicit "acting as" picklist in the UI, which every write function validates against real `internal_admin`/`internal_ops` rows via `assert_internal_actor()`. `auth.uid()` is meaningless here — a `service_role`-authenticated call carries no user claims — so don't look for it in `audit_log`; look at the `p_actor_id` you passed instead.

## 1. Two Retool resources, two different trust levels

### 1a. Postgres resource (reads only)

Project Settings → Database in the Supabase dashboard has the connection details (host, port, database, user, password — use the pooler connection, not direct, for Retool). I don't have this password; only you can retrieve or reset it from the dashboard.

**Important trust note:** the standard Postgres connection role is not subject to RLS the way `authenticated`/`anon` are — Retool's queries will see every company's rows regardless of tenant. That's expected and fine for an internal ops tool, but it means Retool itself is the only thing standing between an ops user and cross-tenant data, not RLS. Two consequences for how you build queries:

- Never build a Retool view that lets one company see another's orders as a *feature* — always filter explicitly (`where company_id = {{ select.value }}` etc.) even though the connection *could* return everything.
- Don't give Retool viewer/editor access to more staff than need it — it's the actual security boundary here, not a defense-in-depth layer.

Use this resource for: the order list/table, order detail lookups, the company/employee/kit_type dropdowns you'll need to populate forms, and the "acting as" staff picklist (query `select id, full_name from users where role in ('internal_admin','internal_ops') order by full_name`).

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

## 2. The three write endpoints

All three require the caller to already be authenticated as `service_role` (checked via `auth.role()` inside the functions, redundant with the fact that only `service_role` has EXECUTE at all) — a normal Retool REST query using the resource above satisfies this automatically.

**Gotcha:** the two RPCs and the Edge Function use different parameter-naming conventions. Don't copy-paste one query's body shape into another.

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

Leave `p_order_reference` as `null` unless you're deliberately overriding the atomic reference generator (you shouldn't need to). `p_service_type` is `'return'` or `'ship_to_new_employee'` — only supply `p_return_address_id` for the former, only `p_employee_id` for the latter, matching the same shape `create_order()` already enforces for customer-placed orders. Returns the new order row; the reference comes back matching `RK[LTPMA]-YYMMDD-NNN`.

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

A minimal but complete ops app needs four things:

**Order list.** A Postgres-backed table, default sorted newest first. Filters on `fulfilment_status`, `service_type`, `company_id`, and a date range on `created_at`. Surface `reference`, `company`, `kit_type`, `service_type`, `fulfilment_status`, `outbound_tracking_number`, `created_at` as columns. Clicking a row selects it for the action panel below.

**Acting-as picklist.** One select, populated from the `internal_admin`/`internal_ops` query above, pinned somewhere always-visible (top of the page, not per-form) since every write needs it. Consider persisting the last-used value in Retool's local storage so staff don't re-pick it every session.

**Dispatch panel.** Visible when the selected order's `fulfilment_status = 'awaiting_dispatch'`. Courier text input, tracking number input, optional tracking URL input, a "Mark dispatched" button wired to the `mark_order_dispatched` query. On success, refresh the order table query.

**Manual order form.** A modal or separate tab: company select, kit type select, service type radio, then conditionally an employee select (ship-to-new-employee) or return-address select (return), device reference, send date / leaver last day date pickers, optional bundle ID. Submit wired to `create_internal_order`. On success, show the returned reference and refresh the order table.

**Print Pack button.** On the order detail panel (or as a table row action), calls `generate-print-pack` and opens the signed URL. Useful on any order regardless of status, but most relevant once dispatched.

Not in scope for Phase 4 (per the implementation plan — don't build ahead): Sendcloud label purchase automation (Phase 6, still manual in Sendcloud's own dashboard), Confirm Sent/Received (that's the customer, in Lovable, not staff in Retool), credits/promo, bulk CSV ordering.

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
