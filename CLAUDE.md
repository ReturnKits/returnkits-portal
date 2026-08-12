# ReturnKits Customer Portal

Multi-tenant portal for a UK IT asset recovery / reverse logistics business. Customers order kits to return or redeploy hardware; ReturnKits fulfils and tracks them.

**Status:** greenfield. No code yet. Rebuilding off a Base44 prototype (schema validated, no real data — see `docs/returnkits-base44-audit.md`).

## Documents — read before building

| Doc | What it is |
|---|---|
| `docs/returnkits-portal-architecture.md` | The design. Every decision, with reasoning. Sections referenced as §N. |
| `docs/returnkits-implementation-plan.md` | Phases 0–14 with exit criteria. **Follow this order.** |
| `docs/returnkits-getting-started.md` | Stack, tooling, setup commands. |
| `docs/returnkits-base44-audit.md` | What went wrong in the prototype. Explains several design choices. |

When a decision seems arbitrary, it's in the architecture doc with reasoning. Check before changing it.

## Build approach

| Layer | Built with |
|---|---|
| Database, RLS, migrations, tests | **Hand-written SQL** — never generated |
| Money & concurrency (webhooks, credits, references) | **Hand-written** — never generated |
| Customer portal UI | **Lovable** (real React/TS, two-way GitHub sync) |
| Ops dashboard | **Retool** over the same Postgres |

**The governing rule: you own the schema. Lovable builds on top of it. The RLS suite is the gate.**

Create tables and policies first, then point Lovable at the existing Supabase project. If Lovable designs the schema it will produce permissive RLS that looks correct but fails cross-tenant rigour — exactly the bug the Base44 audit found. Run the RLS suite after anything Lovable changes.

## Stack

TypeScript · Next.js 15 (App Router) · Supabase (Postgres + Auth + Storage + Edge Functions, **London region**) · Lovable · Retool · Stripe · Sendcloud · Resend + React Email · Tailwind + shadcn/ui · Zod · Vitest · Sentry

**Single app, not a monorepo.** Business logic lives in `lib/`. There is no `apps/ops` — that's Retool.

## Non-negotiable rules

1. **RLS test suite must be green.** Never ship with it red. Tests assert *both* directions: company A can't read company B's data, **and** user 2 in company A *can* read user 1's orders. The prototype silently failed the second one for months.
2. **`service_role` key never reaches the client.** Not in the portal bundle, not in `NEXT_PUBLIC_*`. Retool holds its own privileged connection server-side.
3. **All permission checks go through `can(user, action, resource)`** in `lib/`. Never inline `if (user.role === 'admin')`.
4. **Every inbound webhook is signature-verified and idempotent**, keyed on the provider's event ID. Stripe, Sendcloud, Resend, BambooHR. **Hand-written, never generated.**
5. **Money is integer pence. Prices stored ex-VAT only**, inc-VAT computed at display. The prototype stored both and they drifted.
6. **New tenant-scoped table** → RLS policy + both test directions land in the same commit.
7. **Retool writes call the app's API**, never straight to tables. Reads may hit Postgres directly. Retool bypasses RLS, so audit logging happens in the API or via DB triggers.
8. **Dates in Europe/London.** Order references, working-day calculations, and dispatch windows all derive from business-local dates, not UTC.
9. **Review every migration Lovable proposes** before applying it.

## Locked decisions (don't re-litigate)

- **Flat order model** — one `orders` row per kit, tracking columns on the row, `bundle_id` groups multi-item orders. No separate `kits`/`shipment_legs` tables.
- **No guest orders.** `company_id` is `NOT NULL` everywhere. One tenant path per RLS policy.
- **Invite-only company joining.** Signed single-use expiring tokens are the sole access grant. `companies.domain` is descriptive metadata and must **never** be used for authorization.
- **Self-serve signup** — anyone can register a company. No card required at signup.
- **Prices ex-VAT**: Laptop £65, Phone £40, Monitor £85. Tablet and Accessories exist but inactive. VAT shown as a separate line at cart, checkout, and invoice.
- **Enhanced Cover** (never call it "insurance" — FCA): £5/£10/£20 ex-VAT for £500/£1,000/£2,000, carrier declared-value passthrough, separate invoice line, 20% VAT.
- **Credits typed per kit type.** Laptop credits can't buy phone kits. Append-only ledger; balance is the `SUM`.
- **No refunds.** Cancellation is an admin-only state. Purchased credits are restored; **promo credits are forfeited**.
- **Order references**: `RKL|RKT|RKP|RKM|RKA-YYMMDD-NNN`, bundles `BND-YYMMDD-NNN`. Atomic generation via `reference_counters`, immutable once issued, rolls to 4 digits past 999. **Never parse by fixed width** — split on `-`.
- **Invoice numbers** are a *separate*, strictly gapless Postgres sequence (UK VAT requirement). Cancelled invoices are voided, never deleted.
- **SLA**: next-working-day dispatch, working days exclude UK bank holidays.
- **Shipping**: Sendcloud, behind a `ShippingProvider` interface. Tracking statuses normalised to our own enum. Provider is expected to change.
- **`fulfilment_status` has an `in_transit` state (added 20260811, Phase 6 tracking).** Set automatically by `apply_sendcloud_tracking_event()` off real Sendcloud parcel-status-changed webhooks — never by a staff RPC. Both legs use the same status name, whichever leg (`outbound_tracking_number` or `return_tracking_number`) is currently active on the order. `mark_return_completed` and `confirm_received` both accept `'dispatched'` or `'in_transit'` as their pre-state, so a real tracking scan landing before close-out never blocks staff/customer from completing the order manually.
- **Phase 6 is tracking-only, not label automation.** Labels stay manual in Sendcloud's dashboard (decision 20260811: "I will do labels manually but we need tracking in the portal") — no `buyLabel`, rate shopping, or address validation was built. Sendcloud webhooks are scoped to the *integration* a parcel belongs to, not to how the label was created, so a manually-created label still fires `parcel-status-changed` events; the "return parcels only get webhooks if the outgoing shipment was created through the API Shop" caveat in Sendcloud's docs is read as referring to their own RMA/returns-portal product, which ReturnKits doesn't use — worth confirming empirically against the first live return order. `sendcloud-webhook` (Edge Function) verifies the HMAC-SHA256 `Sendcloud-Signature` header (hex-encoded, not base64) and calls `apply_sendcloud_tracking_event()`, which matches by tracking number and looks up `sendcloud_status_map` to normalise Sendcloud's `status_code` vocabulary. That map is a best-effort seed, not a verified full list (Sendcloud's live status API wasn't reachable to enumerate it) — extend via plain SQL insert as real payloads are observed, no redeploy needed. Unmapped codes are logged and ignored, never guessed into a wrong transition.
- **Employees never log in.** `employees` is a recipient directory (name, email, address, last-kit-ordered) — not a portal user, no auth identity, no RLS-scoped access of their own. The leaver/joiner just receives a physical kit. Every order action (creation, `confirm_received`) is performed by the company's portal user who placed the order, and every notification email (confirmation, dispatched, check-ins) goes to that user (`orders.created_by` → `users.email`) — never to the employee's address on file. If a later phase wants to reach the employee directly (e.g. a delivery confirmation link, SMS), it needs its own signed/tokenized one-off flow, not portal login.
- **`mark_order_dispatched` refuses to dispatch an unpaid order (added 20260811).** `payment_status` must be `'paid'`, no exceptions — but `payment_status` is only otherwise set to `'paid'` by `record_stripe_payment` (the Stripe webhook), and orders created manually in Retool via `create_internal_order` (`source = 'internal_staff'`) never go through Stripe checkout. `mark_order_paid(order_id, actor_id)` is the staff-only escape valve — a logged, service_role-gated way to mark an order paid for invoiced/offline/comped arrangements before dispatching it. Same auth pattern as every other Retool write.
- **`cancel_order(p_order_id, p_actor_id, p_reason default null)` (added 20260812).** The only way to move an order into `fulfilment_status = 'cancelled'` — cancellation was previously undesigned/unbuilt (per the deferred-until-credits note above). Same auth pattern as every other staff-only RPC: `service_role` only + `assert_internal_actor`, logged to `audit_log` and appended to the order's own `fulfilment_log`. Only succeeds while `fulfilment_status = 'awaiting_dispatch'` — anything already dispatched needs a real-world return, not a status flip. Sets both `fulfilment_status` and `payment_status` to `'cancelled'`; no invoice voiding or credit restoration yet (credits don't exist until Phase 8 — deliberately not built ahead). Exposed in Retool as a "Cancel order" button, same pattern as `mark_order_paid`.
- **No customer confirmation for return orders.** There is no `confirm_sent` action — a customer's own say-so that they've posted a device back isn't verifiable, so it was removed (20260811090000). Return orders stay in `dispatched` until either staff record physical receipt or a future Sendcloud tracking integration confirms it; the check-in nudge (`checkin_sent`) keeps reminding the customer every few days in the meantime, indefinitely, until that signal arrives. `confirm_received` (ship-to-new-employee orders) is unaffected — that's a real, verifiable endpoint and still works as before.

## Build order

Phases 0–5 are the launch build (~5–7 weeks); everything after is demand-driven. **Do not build ahead.** Deferred at launch: bulk CSV ordering, inventory, credits/promo, Enhanced Cover, KB, MDM, BambooHR, escalation, HubSpot sync, API keys, SMS.

Labels are still bought **manually in Sendcloud's dashboard** — Phase 6 only added tracking webhooks, not label purchase automation. Deliberate — two minutes per order at launch volume, zero build time for that part.

Current phase: **6 (tracking-only) — Sendcloud webhook integration**. Phases 0–5 (foundations through notifications) are done and verified live.

## Gotchas from the prototype

- Base44 declared enums but didn't enforce them — 51 of 54 orders held a status the schema prohibited. Use `CHECK` constraints and Zod at every boundary.
- No foreign keys meant 9 of 11 companies referenced users that didn't exist. Add FKs on every relation.
- No transactions meant the free-kit claim marked itself claimed *before* granting the credit. In Postgres, use one transaction with a conditional `UPDATE ... WHERE claimed = false RETURNING`.
- Two companies both claimed `gmail.com` as their domain. This is why domain-based joining was removed entirely.

## Environment

Secrets in Supabase Vault, never plain DB columns or committed config. Stripe and Sendcloud stay in test mode until the launch gate. Supabase project region must be **London (eu-west-2)**.
