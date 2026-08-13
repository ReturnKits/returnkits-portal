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
- **Enhanced Cover** (never call it "insurance" — FCA): £5/£10/£20 ex-VAT for £500/£1,000/£2,000, carrier declared-value passthrough, separate invoice line, 20% VAT. **Built out of order, 20260812** — originally Phase 10/deferred, but enterprise pricing had already been quoted to a prospect assuming it existed, so it was pulled forward. `cover_tiers` (id/label/max_value_pence/price_ex_vat_pence/vat_rate/active) — same world-readable-but-read-only RLS shape as `kit_types`, no write policy, managed by migration only. `orders.cover_tier_id` + `orders.cover_price_ex_vat_pence` snapshotted at order creation via `create_order`/`create_internal_order`'s optional `p_cover_tier_id` param, same immutable-snapshot pattern as kit price. `create-checkout-session` adds cover as its own Stripe line item per order, never folded into the kit line, VAT computed from `cover_tiers.vat_rate`. **Declared value still has to be entered manually in Sendcloud when staff buy the label** — Phase 6 never built `buyLabel()` automation, so there's no API path to pass it through; the Retool order panel shows the cover tier clearly for exactly this reason. Claims are deliberately minimal: `flag_cover_claim(p_order_id, p_actor_id, p_notes default null)` (staff-only, same `service_role` + `assert_internal_actor` pattern as `cancel_order`/`mark_order_paid`) just records that a claim was filed — actually pursuing it with the carrier is still a phone call/email a human makes, not something the app does.
- **Credits typed per kit type.** Laptop credits can't buy phone kits. Append-only ledger; balance is the `SUM`. **Built 20260812 (prepaid credits only — pulled forward same day as Enhanced Cover, in response to "make it easier to order without paying constantly").** Scope locked with the user: prepaid credits only, no free-kit promo (§22 stays unbuilt — that's the part of the design that actually needs the "was this claimed atomically" bug class this project's audit flagged; nobody's asked to prepay yet outside this exact request). Same per-unit price as self-serve `kit_types` — no bulk/volume discount logic. `credit_ledger` (id/company_id/kit_type_id/transaction_type[`purchase`|`redemption`|`adjustment`]/direction[`credit`|`debit`]/quantity/balance_after/order_id/invoice_id/stripe_checkout_session_id/reason/actor_id/created_at), same RLS shape as `invoices` (own company + internal_ops), no insert/update/delete policy for authenticated — every write goes through a RPC or the webhook. `orders.paid_with_credit` + `orders.credit_transaction_id` snapshot which redemption (if any) financed the order; a `orders_credit_snapshot_consistent` CHECK keeps the two in lockstep. **v1 restriction:** a credit-paid order can't also carry Enhanced Cover (`orders_credit_excludes_cover` CHECK) — credit only ever covers the kit, and "partly paid by credit, partly owed by card for cover" was exactly the kind of complexity this scope decision was meant to avoid. `create_order`/`create_internal_order` take an optional `p_pay_with_credit` param: checks the balance inside the same transaction as the debit insert (concurrent redemptions for the last credit serialize, never double-spend — same atomicity discipline as `next_reference_number`), creates the order already `payment_status = 'paid'`. Buying credits is always by card — `create-credit-checkout-session` (Edge Function) creates a Stripe Checkout Session, `record_credit_purchase` (webhook-only RPC, same `stripe_webhook_events`-keyed idempotency pattern as `record_stripe_payment`) issues a real gapless invoice number and credits the ledger. **Saved card is for topping up only, never for paying an individual order directly** — `create-card-setup-session` creates a Stripe Checkout Session in `mode:'setup'` (no charge), `record_card_setup` (webhook-only) caches the resulting PaymentMethod id on `companies.stripe_payment_method_id` and sets it as the Stripe customer's default payment method so the next credit purchase offers it as a one-click option. `stripe-webhook` now branches on `metadata.type` (`order_payment` — the default/legacy case for sessions with no `type` at all — `credit_purchase`, or `card_setup`) to route to the right RPC. `cancel_order` restores 1 credit (an `adjustment` ledger row, not a mutation of the original debit) when the cancelled order was `paid_with_credit` — consistent with the existing "purchased credits are restored" rule below, since every credit in this v1 is a purchased one.
- **No refunds — and never automated.** Cancellation is an admin-only state (`cancel_order`). Purchased credits are restored; **promo credits are forfeited**. When a genuine refund is owed (e.g. a paid-by-card order cancelled before dispatch), that's a **manual action staff take directly in the Stripe dashboard** — `cancel_order` only ever updates our own tables and never calls the Stripe API, by design. Confirmed with the user 20260813: refunds will always be issued manually, no `create_refund`/Stripe refund API integration is planned.
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

Phases 0–5 are the launch build (~5–7 weeks); everything after is demand-driven. **Do not build ahead.** Deferred at launch: bulk CSV ordering, inventory, free-kit promo, KB, MDM, BambooHR, escalation, HubSpot sync, API keys, SMS. (Enhanced Cover and prepaid credits were both pulled forward on 20260812 — see the locked decisions above — everything else in this list is still genuinely not built. Promo credits specifically are still not built — only the prepaid-purchase half of the credits design shipped.)

Labels are still bought **manually in Sendcloud's dashboard** — Phase 6 only added tracking webhooks, not label purchase automation. Deliberate — two minutes per order at launch volume, zero build time for that part.

Current phase: **6 (tracking-only) — Sendcloud webhook integration**. Phases 0–5 (foundations through notifications) are done and verified live.

## Gotchas from the prototype

- Base44 declared enums but didn't enforce them — 51 of 54 orders held a status the schema prohibited. Use `CHECK` constraints and Zod at every boundary.
- No foreign keys meant 9 of 11 companies referenced users that didn't exist. Add FKs on every relation.
- No transactions meant the free-kit claim marked itself claimed *before* granting the credit. In Postgres, use one transaction with a conditional `UPDATE ... WHERE claimed = false RETURNING`.
- Two companies both claimed `gmail.com` as their domain. This is why domain-based joining was removed entirely.

## Environment

Secrets in Supabase Vault, never plain DB columns or committed config. Supabase project region must be **London (eu-west-2)**.

**Stripe went live 20260812.** `STRIPE_SECRET_KEY` (Edge Function secret) was cut over to a live key. Sendcloud's live/test status wasn't part of this cutover and hasn't been separately re-confirmed — check before assuming it's live too. Stripe scopes Customer objects to test/live separately, so the first live checkout failed ("a similar object exists in test mode, but a live mode key was used") — Sentry caught it, fixed by migration `20260812180000_clear_stale_test_mode_stripe_customer_ids.sql` nulling every cached `companies.stripe_customer_id` so `create-checkout-session`'s existing lazy-create path re-created them against the live key. Verified working end-to-end same day: invoice #5 (`cs_live_...`, £48.00 inc VAT) went through the full live pipeline — checkout → Stripe → live webhook → signature verified → `record_stripe_payment` → invoice issued. That order was later cancelled via `cancel_order`; per the no-automated-refunds rule above, any refund on it has to be issued manually in the Stripe dashboard — `cancel_order` never touched Stripe.
