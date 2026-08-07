# ReturnKits Customer Portal — Architecture

> **Build approach (decided):** the customer portal is built in **Lovable** (real React/TypeScript, two-way GitHub sync, native Supabase — you own the code), the ops dashboard is **Retool** over the same Postgres, and the **database, RLS, and anything touching money or concurrency are hand-written**. This collapses the original two-app monorepo into a single Next.js app plus a SaaS admin tool.
>
> **Every design decision below still holds.** What changed is who builds each layer. Where this doc says "the ops app", read "Retool"; where it describes `packages/core`, read `lib/` inside the single app. See `returnkits-implementation-plan.md` for the revised phasing.

## 1. Stack Recommendation

| Layer | Choice | Why |
|---|---|---|
| Frontend | Next.js (App Router), TypeScript, Tailwind — **scaffolded in Lovable** | Server components for data-heavy views, API routes co-located. Lovable generates real code synced to GitHub, so it's editable in any IDE later |
| Ops dashboard | **Retool**, connected to the same Postgres | Purpose-built for internal CRUD over a database; free to 5 users. Reads hit Postgres directly, **writes call the app's API** so order rules aren't reimplemented |
| Database | Postgres (Supabase or RDS) with Row-Level Security | You already named RLS as the isolation mechanism — Postgres RLS is the direct, native way to get it, not app-layer filtering |
| Auth | Supabase Auth or Auth.js (NextAuth), JWT with `company_id` + `role` claims | Claims feed straight into RLS policies; supports magic-link, SSO later |
| API layer | REST (or tRPC internally, REST/GraphQL externally) behind a thin service layer, not raw DB access from the client | Satisfies "stateless connectivity" — every request is a self-contained, authenticated call (JWT or API key), no server session state |
| Background jobs | Queue (Supabase Edge Functions + pg_cron, or BullMQ/Redis, or SQS) | PDF generation, nudge reminders, webhook delivery, invoice sync must not block request/response |
| Object storage | S3-compatible bucket | Print Packs (PDFs), invoices, uploaded documents |
| Email | **Resend** (account already exists) | Bundle-aware: one email per bundle, gated by notification preferences. React Email for templates keeps them in the same codebase and type-checked |
| Webhooks/API keys | Per-company API keys + outbound webhook subscriptions | HubSpot and customer-system integration without polling |
| Payments | Stripe (Checkout/Payment Intents + webhooks) | Credit purchases; Stripe webhook → `payment_intent.succeeded` writes a positive `credit_ledger` entry |
| Shipping/carriers | EasyPost, behind a provider-agnostic interface (§7) | Label generation, rate shopping, address validation, tracking. Treated as swappable — one adapter module, normalized data everywhere else |

Confirmed: the portal is the system of record — its Postgres instance is where orders, kits, shipments, invoices, and credits actually live, not a frontend on top of a separate ops system. That simplifies the design: no dual-write consistency problem, no sync lag between "what the customer sees" and "what's true." §6 still sketches the seam to keep open in case a warehouse/fulfillment system gets bolted on later, but it's not a day-one concern.

## 2. High-Level Shape

```
┌─────────────────────┐        ┌──────────────────────────┐
│  Customer Portal Web │◄──────►│  API Layer (REST, JWT/    │
│  (Next.js)           │        │  API-key auth, stateless) │
└─────────────────────┘        └───────────┬───────────────┘
                                            │
                    ┌───────────────────────┼───────────────────────┐
                    ▼                       ▼                       ▼
           ┌────────────────┐     ┌──────────────────┐    ┌──────────────────┐
           │ Postgres (RLS)  │     │  Job Queue/Worker │    │ Webhook Dispatcher│
           │ orders, kits,   │     │ PDF gen, nudges,  │    │ → HubSpot, client │
           │ invoices, addr, │     │ notif dispatch    │    │   systems         │
           │ credits, users  │     └───────┬───────────┘    └──────────────────┘
           └────────────────┘             ▼
                                   ┌──────────────────┐
                                   │  S3 (Print Packs, │
                                   │  Invoices)        │
                                   └──────────────────┘
```

Internal admin (your team) accesses the same API through an elevated role/service key that bypasses per-company RLS filters — one codebase, two trust levels, not two apps.

## 3. Multi-Tenancy & Access Control

Every tenant-scoped table carries a `company_id`. RLS policies key off `auth.jwt() -> company_id` so a query never needs an explicit `WHERE company_id = ?` in application code — isolation is enforced at the database, not trusted to every endpoint author remembering to filter.

Two roles inside a company (`company_admin`, `company_member`), plus your internal role (`internal_admin`, `internal_ops`) which carries no `company_id` restriction and instead uses a separate RLS policy branch (`is_internal() OR company_id = current_company()`).

**No guest orders.** Every order belongs to a company, so `company_id` is `NOT NULL` throughout and every RLS policy has exactly one tenant path. This is a deliberate simplification: a nullable tenant column forces every policy into an `OR` branch, and a policy like `company_id = current_company() OR user_email = current_email()` silently matches rows where both sides are NULL — the single easiest way to leak data across tenants. One non-nullable column is far easier to prove correct, and proving correctness is the point. One-off and phone/email customers are handled by staff creating the order on their behalf (§10), which covers the same need without weakening the model.

### Company joining — invites only

**Email domain plays no part in access control at all.** No auto-matching, no domain verification, no pending-approval queue, no free-email blocklist. There is exactly one way into a company: a signed, single-use, expiring invite sent by a company admin (or by your internal team). Clicking it creates the account already bound to that `company_id` and role. The token is the credential.

This is simpler *and* more secure than domain matching, and it's the reason the DNS-verification machinery isn't needed — that complexity only existed to make domain matching safe, and domain matching is now gone. It also means **any email address works**: personal Gmail, a shared `it@` mailbox, a contractor's own domain. Nobody is locked out for not having a corporate address, which matters when the person handling offboarding logistics often isn't on the company's main email system.

The tradeoff is that a new teammate can't self-serve their way in — an admin has to invite them. For a B2B portal with a handful of users per company that's a few seconds of work, and it's the same model Linear, Notion, and most B2B tools use for private workspaces.

`companies.domain` stays in the schema as **descriptive metadata only** — useful for your team to recognize an account at a glance, never consulted by an authorization check. Worth a comment in the migration saying exactly that, so nobody later "improves" it into an auto-join feature.

Practical notes: invites expire (7 days is a reasonable default), are single-use, store only a hash of the token, and can be revoked by an admin before acceptance. Resending generates a fresh token rather than re-sending the old one.

### Roles and policy shape

Two roles inside a company (`company_admin`, `company_member`), plus your internal role (`internal_admin`, `internal_ops`) which carries no `company_id` restriction:

```
read policy := is_internal()
            OR (company_id = current_company() AND current_company() IS NOT NULL)
```

The `IS NOT NULL` guard is load-bearing, not decoration — it ensures a user with no company (freshly signed up, or pending approval) matches nothing rather than matching every row where `company_id` happens to be NULL. Base44's live policies used the equivalent `$nin: [null, ""]` pattern; worth carrying forward deliberately rather than rediscovering.

## 4. Core Data Model

**Decision: flat order model** — one `orders` row per kit, with outbound and return tracking directly on it, `bundle_id` grouping multi-item orders. No separate `kits` or `shipment_legs` tables. This is the shape proven in the Base44 build (§13); it keeps the common queries (one customer's orders, one order's full journey) single-table, and multi-leg routing complex enough to need normalization isn't part of this business.

- **companies** — id, name, domain (**descriptive metadata only — never consulted for access**, §3), billing_email, address, status, vat_number, stripe_customer_id
- **users** — id, company_id, role, email, status (invited / active)
- **invites** — id, company_id, email, role, token_hash, expires_at, accepted_at, revoked — single-use, expiring; the token is the only way into a company (§3)
- **addresses** — id, company_id, label, address fields, is_default_return — fixed locations (warehouse, IT office)
- **employees** — id, company_id, full_name, email, phone, address fields, last_kit_ordered_at — recipient people, distinct from fixed addresses (§13)
- **orders** — id, company_id (**NOT NULL** — every order belongs to a company, §3), user_email, bundle_id, reference (`RKL-260807-001` format, immutable — §21), order_reference (customer's own PO/ticket ref), service_type (return / ship-to-new-employee), kit_type, device_reference, payment_status, fulfilment_status, source (`customer` / `internal_staff` / `bamboohr_auto`), requested_send_date, leaver_last_day, recipient_* fields, return_* fields, outbound_tracking_number / courier / url, return_tracking_number / courier / url, additional_tracking[], fulfilment_log[], checklist, confirm_sent_checkin_due_at, confirm_received_checkin_due_at, skip_recipient_notifications, paid_with_credit, credit_transaction_id, price_ex_vat, price_inc_vat
- **bundles** — id, company_id, reference (`BND-260807-001`), created_at — groups orders placed together; drives one confirmation email and one line-item invoice
- **reference_counters** — prefix, ref_date, last_value — atomic daily-resetting counters backing the reference format (§21)
- **invoices** — id, company_id, order_ids[], stripe_invoice_id, invoice_number, amount_total, currency, status, pdf_url, hosted_url, issued_date
- **credit_ledger** — id, company_id, **kit_type**, transaction_type (purchase/redemption/adjustment), direction (credit/debit), quantity (always positive), balance_after, order_id, stripe_session_id, reason/notes, actor_email, created_at — append-only. **Credits are typed per kit type**: balance is `SUM(signed quantity) GROUP BY company_id, kit_type`, so a laptop credit can't be spent on a phone kit. Never mutated in place.
- **notification_preferences** — id, company_id, recipient scope, event_type, enabled
- **communication_log** — id, order_id, company_id, channel, type, audience (customer/internal), recipient, subject, status — customer-visible record of what was actually sent (§13)
- **support_requests** / **kb_articles** — see §15
- **api_keys** — id, company_id, key_prefix, key_hash, scopes, revoked, expires_at, last_used_at
- **api_rate_limits** — bucket_key (`${api_key_id}:${minute}`), count — DB-backed so limits survive cold starts (§13)
- **api_request_log** — company_id, api_key_id, endpoint, order_id, status, ip
- **webhook_subscriptions** — id, company_id, url, event_types[], secret
- **audit_log** — actor_id, action, target_table, target_id, before/after — every internal-admin action on customer data

Two notes on the flat model: the `orders` table is wide, so index deliberately (`company_id`, `user_email`, `bundle_id`, `fulfilment_status`, tracking numbers) rather than assuming Postgres will cope — and because a "leg" is now a set of columns rather than a row, tracking-webhook handlers (§7) must know which leg they're updating (outbound vs return) from the tracking number they matched on.

## 5. Feature-to-Architecture Mapping

**Bundle awareness.** Bundling is a first-class table, not a UI grouping trick. All emails, invoices, and Print Packs key off `bundle_id`; the notification worker fires once per bundle-completion event, not once per kit.

**Notification control.** `notification_preferences` is checked by the worker before every send — internal admins mute noisy events (e.g., "order.status_changed") without touching code. Defaults ship sane per event type; overrides are company-scoped.

**Branded Print Pack.** Triggered async on shipment-leg creation (queue job), rendered server-side (e.g., React-PDF or Puppeteer against an HTML template), written to S3, linked from the order and emailed as an attachment. Never generated synchronously in the request path — PDF rendering is slow and shouldn't block order creation.

**Confirm Sent/Received.** Two explicit customer-facing actions that advance `fulfilment_status` and stamp the confirmation timestamp on the order. Each transition records who confirmed and when (accountability, not just tracking) in `fulfilment_log`. The nudge scheduler works off `confirm_sent_checkin_due_at` / `confirm_received_checkin_due_at` — set from `leaver_last_day` where known (a business date the customer actually recognizes) rather than a fixed timer after dispatch, and cleared once confirmed or the order closes.

**Credit management.** Ledger-based, append-only, **typed per kit type** — balances are computed per `(company_id, kit_type)`, so laptop credits and phone credits are separate pools and can't be cross-spent. Redemption at order time is a single transaction: insert order, insert debit ledger entry, both-or-neither (DB transaction, not two API calls). Purchases go through Stripe: portal creates a Checkout session or Payment Intent, Stripe's webhook confirms payment, and only the webhook (never the client) writes the credit entry — so a closed browser tab or failed redirect can't silently lose a paid-for credit. `balance_after` is stored per row for auditability, but the authoritative balance is always the `SUM` — a periodic reconciliation job should assert the two agree and flag drift rather than trusting the cached value.

**Role-based access / RLS.** Covered in §3 — this is the backbone the rest of the portal trusts, so it needs to be correct before anything else ships.

**Stateless connectivity.** Every external integration point (HubSpot, customer's own systems) is either an authenticated API-key call in, or a signed webhook out. No shared session, no server-side state the caller depends on — any request can be retried or replayed safely, and a new integration doesn't require a new code path, just a new API key/webhook subscription.

## 6. Optional Seam (if a future order/warehouse engine appears)

Not needed for launch, since the portal owns the data outright. Worth doing anyway at low cost: put writes behind a service layer instead of raw ORM calls scattered through routes. If a separate fulfillment/warehouse system shows up later, that layer becomes the translation point — Postgres either stays the source of truth and pushes events outward, or becomes a synced read model — without touching the frontend or RLS model.

## 7. Shipping Automation (Carrier Integration)

Provider: **Sendcloud** — UK/EU-native, single REST API covering Royal Mail, DPD UK, and Evri, and (unlike EasyPost) it supports **pickup collection booking via API** for DPD and Evri, which directly enables the self-service pickup feature (§14).

Verified limits worth designing around, because they shape the feature rather than being footnotes:

- **Royal Mail pickups still can't be booked through Sendcloud** — those must be arranged directly with Royal Mail. So pickup self-service works for DPD and Evri, and falls back to the staff-request queue for Royal Mail.
- **DPD and Evri pickups can only be booked for same-day or next business day.** Anything further out errors. The UI must therefore constrain the date picker to today/next working day rather than offering an open calendar — a customer picking "two weeks Friday" is a guaranteed failure. For later dates, capture it as a request and book it when the window opens.
- **Evri collection auto-schedules next-day** pickup, so there's less to choose there.

### Provider abstraction (build this from day one)

The shipping provider is **expected to change** (it already has once, from EasyPost to Sendcloud, before a line of code was written), so it sits behind an internal interface from the first commit — no Sendcloud SDK calls scattered through route handlers or job code. Everything else talks to our own interface, and exactly one adapter module knows what Sendcloud is:

```
ShippingProvider (interface)
  validateAddress(address)      → normalized address + validity
  getRates(shipment)            → [{ carrier, service, cost, eta }]
  buyLabel(shipment, rateId)    → { carrier, trackingNumber, trackingUrl, labelUrl }
  voidLabel(labelId)            → refund/void where supported
  bookPickup(request)           → { pickupRef, window } | UNSUPPORTED
  parseTrackingWebhook(payload) → normalized { trackingNumber, status, occurredAt, detail }
```

`bookPickup` returning an explicit `UNSUPPORTED` (rather than throwing) is what lets Royal Mail fall back to the staff queue while DPD/Evri book automatically — the caller handles one interface, not per-carrier special cases.

Three rules that make the swap actually cheap rather than nominally cheap:

1. **Store normalized values, not provider values.** `orders` holds carrier, tracking number, and tracking URL as plain data (§4) — never an EasyPost shipment ID as the only reference. Keep the provider's ID in a nullable `provider_ref` column for support/debugging, but nothing should *depend* on it.
2. **Normalize tracking statuses to your own enum** at the adapter boundary. Every provider names states differently; if `in_transit`/`out_for_delivery`/`exception` are your own vocabulary, swapping providers means writing one new mapping function, not rewriting the nudge and escalation logic that reads those states (§5, §14).
3. **Webhook verification lives in the adapter**, since each provider signs differently — but the handler downstream receives a normalized event and doesn't care who sent it.

Cost of this discipline: perhaps a day of extra work up front. Cost of skipping it: a provider migration touches the order flow, the worker, the webhook handlers, and the fulfillment UI at once.

### Alternatives worth knowing

If EasyPost doesn't work out, the realistic candidates differ by strength rather than being interchangeable: **ShipEngine** (flat-tier pricing, more predictable budgeting), **Shippo** (better platform tooling, weaker raw API), and UK/EU-native options like **Sendcloud** or **Shiptheory** which have deeper Royal Mail/DPD/Evri integration and, notably, often *do* support collection booking via API — the one thing EasyPost can't do for UK carriers (§14). If self-service pickup scheduling becomes important, that's the most likely reason you'd switch, so it's worth re-evaluating at that point rather than now.

How it plugs into the model already defined:

- **Label generation.** When an order is dispatched (outbound) or a return is initiated, the worker calls EasyPost to buy a label — this returns the carrier, tracking number, and label file, which populate the relevant tracking columns on the order and feed the Print Pack (§5) automatically instead of staff typing tracking numbers in by hand.
- **Rate shopping.** For redeployments where speed/cost trade-offs matter, EasyPost can quote multiple carriers before purchase; the service layer picks by policy (cheapest, fastest, or a preferred-carrier default per company) or surfaces options to internal staff in the fulfillment section (§10) for manual pick on high-value shipments.
- **Address validation.** Run against EasyPost's address verification when a customer saves a new address (§4's `addresses` table) — catches bad warehouse/office addresses before a label is ever purchased, not after a kit is already misrouted.
- **Tracking webhooks — the automation layer.** EasyPost pushes tracking events (in_transit, out_for_delivery, delivered, exception) to your webhook endpoint. This is a second, carrier-verified signal alongside the customer's own Confirm Sent/Received action — it doesn't replace that feature, it backs it up:
  - Carrier says "delivered" but the customer hasn't clicked Confirm Received → trigger an immediate nudge (stronger signal than the time-based nudge already in the design, since you now have proof it arrived).
  - Carrier reports an exception (delayed, returned to sender, lost) → auto-flag the order in the fulfillment section rather than waiting for a customer to notice and report it.
  - This is what actually kills "lost in transit anxiety" — the portal knows before the customer has to ask.
  - Handler note: because the flat model stores outbound and return tracking as separate columns on one row (§4), the webhook handler resolves *which* journey an event belongs to by matching the inbound tracking number against both columns — and must handle the case where the same number appears on `additional_tracking[]` too.

This adds one more background job type to the worker (§1/§2) and one more inbound webhook endpoint (parallel to the Stripe one) — no new architectural pattern, just another event source advancing the same `fulfilment_status`.

## 8. Build Phases

**Decision: full rebuild on Next.js + Supabase.** Base44's schema is treated as a validated reference model (§13) — ported faithfully, not redesigned from scratch — but the app itself is rebuilt with full code ownership.

**Why, ordered by how immediately each one bites:**

1. **The separate admin dashboard isn't achievable on Base44** — the decisive reason. Base44 is one app per project with data scoped to that app, so a genuinely separate ops dashboard means either a second app (its own entity store, can't see your orders) or role-gated routes inside the customer app — a hidden section, not a separate dashboard. "Full control over the functions" (retry a job, pause a queue, inspect why a webhook didn't fire) also needs execution-layer observability a managed builder doesn't expose. Structural, not a matter of trying harder.
2. **Transaction integrity, today.** Base44 can't wrap multi-step writes in a transaction, which is why `claimFreeKit` marks the promo claimed *before* granting the credit (§22) — correct-ish rather than correct. The same applies to credit redemption at checkout (insert order + debit ledger must be all-or-nothing). Money-correctness bugs waiting to happen, not future concerns.
3. **Provable tenant isolation.** Automated cross-tenant tests against Postgres RLS policies (§9) are straightforward; systematically testing JSON policy config is not.
4. **Vendor gating on your own system.** Reading the app's source required a paid plan tier — a preview of depending on someone's pricing for access to your own code.
5. **Enterprise procurement later** — SOC2, pen tests, sub-processor lists. Real, but the weakest reason standing alone.

**Timing:** with 54 test orders and no live customers, this is the cheapest this migration will ever be. The same move in two years with live enterprise clients is a materially worse project.

**No production data exists in Base44** — only test records. That removes the highest-risk item from the plan entirely: no ETL pipeline, no parallel-run period, no cutover risk window. A clean build against a proven schema.

**Caveat that survives the decision: rebuild *narrow*.** The temptation is to rebuild everything Base44 does plus everything in this document. §23 governs — launchable core plus the admin fulfilment view, then let customers decide the rest.

0. **Security foundations** — repo/CI/CD, RLS test suite (both directions — §9.3), the `can()` permission seam (§9.2), audit log table, secrets manager (Supabase Vault), domains/DNS provisioned (§11)
1. **Foundation** — auth, company/user model, RLS policies, invite flow, address book
2. **Core ordering** — orders, kits, bundles, order creation flow
3. **Tracking** — shipment legs, Confirm Sent/Received, status views
4. **Docs & money** — Print Pack generation, invoices, Stripe integration, credit ledger + redemption
5. **Notifications & nudges** — preferences table, communication log, worker, scheduled nudges, escalation policy
6. **Integrations** — API keys (DB-backed rate limiting), webhooks (signature-verified), HubSpot connector, EasyPost shipping automation, MDM adapters
7. **Admin surface** — internal visibility, audit log, fulfillment section, manual order creation, notification suppression controls, analytics
8. **Bulk & inventory** — CSV/multi-recipient bulk ordering, kit_types table, stock movements, low-stock alerts (§16)
9. **Support** — knowledge base, support forms, quick-answers search (§15)
10. **Launch** — go live on `portal.returnkits.com`, no legacy cutover to coordinate

## 9. Security & Reliability Requirements (build checklist, not just design)

### 9.0 The governing principle

Rebuilding on Postgres doesn't make the system secure — it makes security **provable**. That distinction is the whole point. The Base44 audit found tenant isolation applied inconsistently across six entities and nobody noticed for months, because there was no way to assert it. The same mistake is equally writable in Postgres; the difference is that here a test catches it on the next commit.

Everything below follows from that: prefer controls that can be *tested* over controls that must be *remembered*.

### 9.1 Access control architecture

**Four layers, each independently sufficient to stop a leak.** The point of defence in depth is that two unrelated things must both fail before data escapes.

| Layer | Enforces | Fails safe because |
|---|---|---|
| **JWT claims** | Who you are, which company, what role | Signed by Supabase; can't be forged client-side |
| **RLS policies** | Row visibility, in the database | Applies even if application code forgets to filter |
| **Service layer** | Business rules and permission checks | Catches logic errors RLS can't express ("can this user cancel *this* order?") |
| **Route/UI guards** | Not rendering what you can't use | Cosmetic only — never the sole control |

Rule: **application code must never be the only thing standing between two tenants.** If RLS is disabled tomorrow, the service layer should still filter correctly, and vice versa.

**Least privilege on keys.** The `service_role` key bypasses RLS entirely. It exists only in the ops app's server-side environment. Never in the portal, never in a client bundle, never in a `NEXT_PUBLIC_` variable. Add a CI check that greps the build output for the key prefix — a single leaked service key defeats every other control in this document.

### 9.2 Centralise permission checks — the highest-leverage decision

Do **not** scatter `if (user.role === 'admin')` through the codebase. Route every authorisation decision through one function:

```ts
can(user, 'order:cancel', order)   // → boolean
can(user, 'credit:adjust', company)
can(user, 'company:invite', company)
```

Today its implementation can be a simple role lookup. The value is the *seam*: when you later need billing-only access, per-warehouse scoping, client-specific roles, or read-only auditor accounts for an enterprise customer, you change one file instead of auditing 200 routes and hoping you found them all.

This costs nothing now and is the single most effective piece of future-proofing available. Retrofitting it once permission logic is spread through the app is a multi-week job.

Roles at launch: `company_admin`, `company_member`, `internal_admin`, `internal_ops`. Keep them in a table rather than a TypeScript union, so adding one is data rather than a deploy.

### 9.3 The RLS test suite — assert both directions

The Base44 audit's central finding was an **over**-restriction, not a leak: colleagues couldn't see each other's orders. A suite that only tests for leaks would have passed while the product was broken.

Every tenant-scoped table gets both assertions:

```
✗ user in company A CANNOT read company B's rows      (isolation)
✓ user 2 in company A CAN read user 1's rows          (collaboration)
✗ internal_ops CAN read across companies              (admin override works)
✗ user with no company reads nothing                  (null-claim guard)
```

That fourth case is the one that produces silent disasters — a user whose `company_id` claim is missing must match zero rows, never every row where `company_id IS NULL`.

Run against a real local Postgres in CI, on every commit, before any feature work. If this suite is red, nothing ships.

### 9.4 JWT lifetime and revocation

Claims are **cached in the token until it refreshes.** Remove someone from a company and their existing token still carries the old `company_id` until expiry. This is the subtlety most teams miss.

- Access token TTL: **1 hour** (Supabase default; don't lengthen it).
- For genuinely sensitive operations — cancelling orders, adjusting credits, changing billing, any admin action — **verify against the database rather than trusting the claim.** The claim is an optimisation for reads; it is not authoritative for privileged writes.
- Revoking a user sets their status immediately *and* the service layer checks it, so revocation is effective within the request rather than within the hour.

### 9.5 Audit logging from day one

Every internal-admin action on customer data: actor, action, target table and id, before/after, timestamp. Written in the same transaction as the change, so an action can't succeed unlogged.

Retrofitting this is painful and it's the first thing enterprise procurement asks for. It's also what makes the `service_role` bypass acceptable — unrestricted access is defensible when every use is recorded.

Audit rows are append-only and not deletable, including by internal admins.

### 9.6 Authentication hardening

- **Magic-link only at launch** — no passwords means no password breaches, no reuse, no reset flow to attack.
- **Design for SSO now, build it later.** Keep company and role assignment independent of *how* someone authenticated, so adding SAML for an enterprise client is configuration rather than a migration.
- **MFA on internal admin accounts** — they bypass per-company RLS, making them the highest-value target in the system.
- **Rate-limit auth endpoints**, not just the API: magic-link requests and invite-token submissions both need throttling, or the invite flow becomes an enumeration oracle.
- **Invite tokens**: single-use, expiring (7 days), hashed at rest, revocable before acceptance.

### 9.7 Perimeter and data handling

- **Webhook signature verification** on every inbound webhook (Stripe, Sendcloud, BambooHR). Unverified webhooks are a direct path to forged payments and fraudulent orders. Verification lives in the provider adapter (§7).
- **Secrets management**: Stripe keys, Sendcloud keys, MDM credentials, BambooHR OAuth tokens all in Supabase Vault — never plain DB columns, never committed config.
- **Signed, expiring URLs for all documents.** Invoices and Print Packs must never sit at guessable storage URLs — a PDF at a predictable address bypasses RLS entirely.
- **Input validation with Zod at every boundary** — one schema validating the form, the API route, and the database write. Enum violations like those found in the Base44 audit become impossible when the same schema guards every path in.
- **Database constraints as the backstop**: `CHECK` constraints on enums, foreign keys on every relation, `NOT NULL` on `company_id`, unique constraints on invoice numbers and references. The audit found all four of these missing — they're the cheapest correctness guarantees available.
- **Dependency and vulnerability scanning** in CI, HTTPS everywhere, sensible CSP headers.

### 9.8 GDPR and processor obligations

You are a **processor** of your customers' employee data — home addresses and personal emails of people who never contracted with you directly. That carries obligations beyond your own privacy policy:

- Customer-facing DPA naming the actual sub-processor list (Supabase, Vercel, Stripe, Sendcloud, Resend, later BambooHR and MDM vendors).
- A documented retention period **with a deletion job that actually enforces it** — a stated policy no code implements is worse than no policy.
- A working right-to-erasure process, including data held in sub-processors.
- **SOC2 readiness** isn't a v1 requirement, but audit logging and access controls should be built as though an audit is coming. Retrofitting them costs far more than building them in from phase 0.

**Reliability** — these are cheap to build in and genuinely painful to retrofit:

- **Idempotency everywhere.** Stripe and EasyPost both retry webhooks; your own job queue will retry failures. Every inbound webhook handler keys off the provider's event ID and no-ops on a duplicate. Every notification carries a dedupe key (`order_id` + `event_type`) so a retried job doesn't email the customer twice. Without this, a retried `payment_intent.succeeded` grants credits twice — a silent money bug.
- **Outbound webhook delivery**: retry with exponential backoff, a dead-letter queue after N failures, and visibility in the admin control plane (§10) when a customer's endpoint is down. Don't let a customer's broken endpoint block your worker.
- **Timezone and working days.** Store all timestamps as `timestamptz`; treat user-facing dates (requested send date, leaver last day) as plain dates in Europe/London. Escalation and nudge thresholds count **working days**, excluding weekends and UK bank holidays — "chase after 5 days" meaning calendar days will fire over a bank holiday weekend and annoy people. Nudges should also respect sending hours (e.g. 08:00–18:00) rather than firing at 3am whenever cron happens to run.
- **Environments**: separate dev / staging / production, with Stripe and EasyPost in test mode outside production. Seed data for staging so the fulfillment views aren't empty.
- **Backup expectations**: Supabase Pro includes point-in-time recovery (7 days on Pro) — confirm that's an acceptable recovery window for order and invoice data before launch rather than after an incident.

## 10. Internal Admin Dashboard

A separate app authenticated with an internal/service role, not a customer role — bypasses per-company RLS, sees across all tenants, and every write it makes is logged to `audit_log`. It calls the same internal service layer as the customer portal (§6), never a duplicate set of business logic — the difference is permission scope, not code path. Now that a subdomain split is confirmed (§11), this is a genuinely separate Next.js app deployment, not just a gated route group — a cleaner security boundary than "same app, different route."

**Control plane.** Visibility into background jobs (PDF generation, notification dispatch, nudge scheduling, webhook delivery): retry a failed job, pause a queue, force-send a notification, regenerate a Print Pack on demand. Also where notification suppression (§5) is configured per company.

**Fulfillment section.** Cross-company view of every shipment leg — status, carrier, tracking number, sent/received confirmation timestamps. Staff can update carrier/tracking details, override a leg's status (e.g., mark received on a customer's behalf when they call in), flag/resolve exceptions, and regenerate documentation. This is the operational nerve center for anything that doesn't go cleanly through customer self-service.

**Manual order creation.** Staff can create an order on behalf of any company — same order/bundle/kit creation flow the customer portal uses, just invoked with an internal actor and a company selected explicitly rather than inferred from the logged-in user's `company_id`. Add a `source` field on `orders` (`customer` vs `internal_staff`, plus `created_by`) so reporting and audit trails can distinguish self-service from phone/email orders without changing the underlying model.

**Full order control.** Edit, cancel, or reassign existing orders; override statuses; adjust or credit invoices; manually adjust the credit ledger (with a mandatory reason code, since it's append-only and every entry is audit-visible). These are privileged mutations — the internal role's RLS branch permits them, the customer role's never does.

**Analytics.** Order/bundle volume and mix over time, transit-time distribution per leg, sent→received confirmation lag by company/carrier, exception and nudge-trigger rates, credit balance and burn rate per account, notification delivery/suppression stats. Built as read models (materialized views or a lightweight reporting schema) over the same Postgres data — no separate analytics database needed at this scale.

## 11. Domain & Subdomain Architecture

**Decision:** customer portal lives at `portal.returnkits.com`. Internal admin (§10) gets its own subdomain — recommend `ops.returnkits.com` or `admin.returnkits.com`. Each is a separate deployment (separate Vercel project), not one app serving multiple hostnames — this is what makes "a full separate dashboard" (your earlier requirement) actually true at the infrastructure level, not just a UI convention.

Why separate subdomains earn their keep beyond organization:

- **Session isolation.** No shared root-domain cookie (`.returnkits.com`) — `portal.returnkits.com` and `ops.returnkits.com` each get their own scoped auth session. A stolen customer-portal session cookie has zero reach into the admin dashboard, and vice versa. This is a real security boundary, not just tidiness.
- **Independent deploys.** Ship an admin-dashboard change without touching or redeploying the customer portal, and the reverse. Useful once both are being actively developed in parallel.
- **Room to grow.** Future subdomains slot in the same way with no architectural rework — `api.returnkits.com` for the external-facing API/webhook surface (keeps integration partners pointed at a stable, documented host separate from wherever the portal's internal routes happen to live), `status.returnkits.com` for a public uptime page later if you want one.

Practical setup: DNS and SSL are handled per-subdomain automatically on Vercel (or add Cloudflare in front for WAF/DDoS protection if that becomes a priority) — no manual certificate management. Supabase Auth is configured per app with its own redirect URLs and JWT audience per subdomain, reinforcing the session isolation above rather than relying on convention alone.

## 12. UK-Specific Considerations

- **Hosting region.** Set the Supabase project region to London (AWS `eu-west-2`), not the US default. Note that "Europe" as a grouping includes London and Zurich — neither is an EU member state, but both carry GDPR-adequacy status, which is what matters for a UK-based company handling UK/EU customer data. Get Supabase's DPA (Data Processing Agreement) signed — selecting a region alone doesn't make you compliant; backups, logs, and Edge Function execution location also factor into the residency picture.
- **Vercel** deploys to the edge nearest the request by default — no action needed, but keep primary compute/functions colocated with the London database region to avoid cross-region latency on every DB-backed request.
- **Carriers.** EasyPost has solid UK coverage — Royal Mail (including Parcelforce), DPD UK, and Evri are all supported, which covers the vast majority of UK B2B parcel movement. International/customs handling (useful if any customer sites are outside the UK) is one of EasyPost's stronger areas.
- **Payments.** Stripe fully supports UK merchants — GBP as the default currency, and Stripe Tax can handle VAT calculation on credit purchases/invoices automatically rather than you hardcoding a rate.
- **Invoicing.** UK VAT invoices have specific required fields (your VAT registration number, a sequential invoice number, invoice date, VAT breakdown per line). Add a `vat_number` field to `companies` and make sure the invoice/Print Pack PDF template includes these — worth confirming with an accountant before the invoice template is finalized, since Claude isn't a substitute for tax/legal advice here.

## 13. Learnings From Your Previous Base44 Build

Pulled directly from the existing ReturnKits Base44 app's entity schemas — this validates most of the design above and surfaces gaps to close before build. (No production data exists in this app — see §8 — so this is purely a schema/pattern reference, not a data source.)

**Employee directory.** A recipient contact list per company (name, email, address, last-kit-ordered timestamp), distinct from `SavedAddress` (which is for fixed locations like warehouses or IT offices). This matters specifically for "ship to new employee" / leaver-return flows where the recipient is a person, not a location — the order picks a recipient from this list rather than the customer re-typing an address every time.

**Customer-visible communication log.** Rather than only a `notification_preferences` toggle table, also keep a `CommunicationLog` — every email/SMS actually sent, tagged `audience: Customer | Internal`, with customer-scoped rows readable in the portal itself. This gives customers a "here's everything we've sent you" view and gives your team a debuggable record of what fired and when, separate from whether it was suppressed.

**Flatter order model — adopted (§4).** The Base44 app uses one `Order` record per kit rather than a `kits` + `shipment_legs` split: outbound and return tracking numbers, couriers, and a `fulfilment_log` array live directly on the order, with `bundle_id` grouping multi-item orders. Payment status and fulfilment status are two separate enums on the same record — a genuinely good separation, since "paid" and "shipped" fail independently and conflating them into one status column is a common and painful mistake. The nudge timing off `leaver_last_day` is likewise better than a fixed post-dispatch timer. This shape is now the design, not an alternative to it.

**API rate limiting, DB-backed.** `ApiRateLimit` stores one row per `${api_key_id}:${minute}` bucket in Postgres rather than in-memory — necessary because serverless functions don't share memory across cold starts. Pair with `ApiRequestLog` for per-key observability (status, endpoint, IP) rather than only logging failures.

**Free-kit signup promo.** Carried forward, with the claim reworked to be genuinely atomic and cross-company abuse guards added — see §22.

## 14. Selected Feature Additions

Confirmed for build: self-service pickup scheduling, escalation + billback, MDM integration, BambooHR marketplace integration. Deferred: loaner devices, international shipping.

**Self-service pickup scheduling — with a caveat.** Checked EasyPost's actual API support before designing this: ad-hoc pickup collection booking is **not** available via API for Royal Mail or DPD — those only support pickups arranged as a recurring schedule at carrier account setup, not per-shipment. DPD offers Ship2Shop (drop-off at a pickup point) as an API-accessible alternative, but that's not the same as a courier collecting from the customer's office. Recommended build order: ship v1 as a request queue — customer clicks "Request a pickup" with a preferred date/window, it lands in the admin fulfillment section (§10) as an action item, staff books it directly through Royal Mail/DPD's own web portals and marks it scheduled/confirmed (customer sees status update either way). v2, once pickup-request volume justifies the engineering cost, integrate directly against Royal Mail's and DPD's own collection-booking APIs (separate from EasyPost) to fully automate. Don't build v2 speculatively — it's real integration work for a feature you don't have usage data on yet.

**Escalation + billback.** Extends the existing nudge system (§5) rather than replacing it. Add an escalation policy (nudge-count and days-elapsed thresholds, configurable per company or a sane global default) to the order/leg record. When thresholds are crossed: notify the company's account owner (not just the individual recipient), surface the order in an "Escalated" filter in the fulfillment section, and give internal staff a manual "charge for unretrieved asset" action — a one-off Stripe charge tied to the order, logged with a reason code. Keep billback admin-triggered rather than fully automatic; auto-charging a client's card without a human decision point is a support/dispute risk worth avoiding until the process is proven.

**MDM integration (Jamf, Microsoft Intune/Entra, Kandji).** Same abstraction pattern as carriers (§7) and payments — one internal interface, multiple provider adapters, since different customers will run different MDM platforms. Each company configures its MDM provider and credentials once, in an admin-only settings area (never customer-self-service, since these are highly privileged API keys). On a return order for a matched device (by serial/asset tag), the worker calls the provider's lock-device action; credentials themselves belong in a secrets manager (Supabase Vault), never a plain database column, given what they grant access to.

**BambooHR marketplace integration.** BambooHR moved to real-time event-driven webhooks (no more polling or webhook rate limits), firing on employee status changes including termination — which makes automatic retrieval genuinely buildable: a termination event triggers a "Return to company" order automatically, pre-filled from the employee's BambooHR record (name, last known address) synced into the `Employee` directory (§13). Two things to plan for: this requires becoming an actual listed BambooHR Marketplace app (OAuth registration, partner review, per-customer install/authorization flow) — that's a business/partnership step with BambooHR, not just an engineering task, and worth starting in parallel with the build rather than after. Technically, extend `orders.source` (already `customer` / `internal_staff` per §10) with a third value, `bamboohr_auto`, so reporting can distinguish self-service, staff-initiated, and HRIS-triggered orders.

## 15. Customer Support Features (KB, Forms, Quick Answers)

**Decision: build in-house, inside the portal, rather than bolting on a third-party helpdesk.** A tool like Intercom or Zendesk would be faster to stand up, but it fragments your data — support history lives in a system that doesn't know about `orders`, `company_id`, or RLS, and you lose the "full control" you asked for earlier. Since support requests are naturally scoped to a company and often to a specific order, they fit the existing model directly rather than needing a separate platform. Flag this if support volume grows large enough that a dedicated helpdesk's routing/SLA tooling starts to matter more than data unity — that's a real tradeoff point, just not one to pre-optimize for now.

- **Knowledge base.** A simple `kb_articles` table (title, body, category, slug, published flag) — no headless CMS needed at this scale, just admin-editable content via the internal dashboard (§10). Public-facing at `portal.returnkits.com/help` — worth leaving KB articles unauthenticated (not gated behind login) so they're indexable and useful to a customer *before* they've even signed up, and so support links work when shared externally.
- **Support forms.** A `support_requests` table: company_id, order_id (optional — many requests are about a specific shipment), category, message, status (open/in progress/resolved). Submitting one fires the same notification worker (§5) already built for order events — routes to your team by email/Slack, no new delivery mechanism needed. Shown back to the customer as a "My Requests" tab in the portal with status, mirroring how orders already work.
- **Quick answers.** Start simple: a search-as-you-type filter over KB articles (title/body match, trivial to build directly against Postgres full-text search — no external search service needed at this content volume). Once there's a meaningful body of KB articles and real support-request history, this is a natural place to layer in an AI-assisted answer (a small RAG lookup over the KB content) rather than plain keyword search — but that's a v2 enhancement once there's actually enough content to ground it in, not a day-one build item.
- **Where it sits in the data model:** both `kb_articles` and `support_requests` are company-agnostic and company-scoped respectively, so `kb_articles` has no RLS restriction (public read, admin write) while `support_requests` follows the same `company_id`-scoped RLS pattern as everything else (§3) — no new access-control pattern, just two more tables using the one already proven.

## 16. Operational Model

### Bulk offboarding

A core enterprise use case ("we're offboarding 40 people next month"), so it's a first-class flow rather than 40 trips through the single-order form.

- **Two entry paths, one pipeline.** A multi-recipient builder (add recipients inline, pick from the `employees` directory) and a CSV upload for larger batches. Both produce the same validated list, then the same order-creation transaction — don't build two code paths.
- **CSV handling.** Provide a downloadable template (name, email, address lines, city, postcode, kit type, leaver last day, reference). Parse and validate *before* creating anything, then show a per-row preview with errors flagged inline — invalid postcode, missing kit type, unrecognized kit — and let the customer fix rows in the browser rather than re-uploading repeatedly. Run EasyPost address validation (§7) across the batch at this stage: catching 3 bad addresses out of 40 before labels are bought is the entire point.
- **One bundle, one invoice, N orders.** The batch creates a single `bundle_id` covering all orders, which the existing bundle logic (§5) already turns into one confirmation email and one line-item invoice. This is exactly what bundles were designed for.
- **Partial failure is the interesting case.** If 38 of 40 rows are valid, create the 38 and report the 2 — don't fail the whole batch. Creation runs as a transaction per order inside a batch job, not one giant transaction, so one bad row can't roll back 39 good ones.
- **Credit redemption at batch scale** checks the per-kit-type balance for the whole batch up front (§5) — 40 laptop kits needs 40 laptop credits, and finding out at row 31 that credits ran out is a bad experience. Insufficient credit surfaces before submission, with the shortfall payable by card.
- **Async, not request-scoped.** A 200-row upload runs as a background job with progress shown in the UI — label purchases and Print Pack generation for 200 orders will not finish inside an HTTP request.

### Cancellations — no refunds

**Policy: ReturnKits does not issue refunds.** Cancellation is still a real state that needs modelling, it just doesn't move money back:

- Add `Cancelled` to the fulfilment status enum, with a reason code and cancelling actor recorded. Cancellation is admin-only (§10) — customers request, staff action, which keeps a human in the loop on anything money-adjacent.
- **Card-paid orders**: cancelled, no money returned, per policy. Make this visible in the portal's terms at checkout so it isn't a surprise.
- **Purchased-credit orders**: the credit is restored via a compensating ledger entry. This isn't a refund — no money moves, the company simply keeps the credit it already paid for. (Base44 had a `reverseCreditRedemption` function, so this came up in practice.)
- **Promo-credit orders**: the credit is **forfeited**, not restored — see §22. Cancelling a free kit spends it.
- **Goodwill adjustments** stay possible: the ledger already supports admin `Adjustment` entries with a mandatory reason code (§10), so staff can credit an account for a service failure without that being a "refund".
- Cancelling after a label is purchased should also trigger the carrier refund/void where EasyPost supports it — that's recovering your own cost, unrelated to customer refunds.

One flag: a blanket no-refunds policy is generally more defensible in B2B than B2C, but the terms are worth a solicitor's eye before launch — that's legal territory, not architecture.

### Kit inventory

Portal tracks stock per kit type, decrements on dispatch, and blocks or warns when short.

- **`kit_types` becomes a table, not an enum.** Adding "Desktop Kit" shouldn't require a schema migration, and stock levels need somewhere to live anyway. Fields: name, active, price_ex_vat, stock_on_hand, low_stock_threshold.
- **`stock_movements`** — append-only, same discipline as the credit ledger: kit_type_id, delta, reason (`restock` / `dispatch` / `adjustment` / `write_off`), order_id, actor, created_at. Stock on hand is the `SUM`; a cached column on `kit_types` is fine as long as a reconciliation job asserts the two agree.
- **Decrement on dispatch, not on order placement** — otherwise cancelled and unfulfilled orders quietly eat stock. If you want to prevent overselling a scarce kit, that's a soft reservation with an expiry, which is worth adding only if it turns out to be a real problem.
- **Bulk orders are where this matters most.** A 40-kit batch against 12 in stock needs to surface at submission — the batch validation step (above) checks availability alongside addresses and credits.
- **Low-stock alerts** to your team via the existing notification worker (§5), plus a stock view in the admin dashboard (§10). No new delivery mechanism needed.
- Customers never see stock levels — availability failures surface as "we'll confirm dispatch dates with you", not "only 12 left".

## 17. Decisions Locked In

- **Payments:** Stripe (see §1, §5).
- **Scale:** ~1 user expected initially. Postgres RLS with no caching layer is more than sufficient — this rules out any premature scaling work (read replicas, materialized-view refresh scheduling beyond basic analytics, connection pooling tuning). Revisit only once real company/user counts are known.
- **Auth:** Magic-link/email is sufficient for v1. SSO (SAML/OIDC) is a known future requirement for larger enterprise clients, not a day-one build item. Supabase Auth supports SAML SSO as an add-on, so this is additive later — pick an auth provider now that has a credible SSO story (Supabase Auth or Auth.js with a SAML plugin) rather than one you'd have to migrate off of when the first enterprise client asks for it.
- **Build approach:** full rebuild on Next.js + Supabase, no data migration required (Base44 has no production data — schema used as reference only).
- **Domains:** `portal.returnkits.com` (customer portal), `ops.returnkits.com` or `admin.returnkits.com` (internal dashboard), each a separate deployment with its own session scope.
- **Shipping provider:** Sendcloud — UK-native, supports API pickup booking for DPD/Evri (Royal Mail falls back to the staff queue). Built behind a provider-agnostic interface regardless (§7).
- **Pricing:** Phone £40 / Laptop £65 / Monitor £85, all **ex-VAT**, stored ex-VAT only with inc-VAT computed. Tablet and Accessories retained but inactive. VAT calculation rebuilt correctly — it's broken in Base44 today (§20, §21).
- **VAT display:** ex-VAT prices shown everywhere, VAT as its own line at cart, checkout, and invoice. Amounts stored in integer pence (§20).
- **Order references:** `[RKL|RKT|RKP|RKM|RKA]-YYMMDD-NNN`, bundles as `BND-YYMMDD-NNN`. Atomically generated, date in Europe/London, immutable once issued, sequence rolls to 4 digits past 999. Invoice numbers stay a separate gapless sequence (§21).
- **Signup:** self-serve — anyone can register a company and order. No card required at signup (§22).
- **Free kit promo:** 1 Laptop Kit credit, claimed via a single atomic transaction. Guarded by verified email, disposable-domain blocking, and delivery-address dedup rather than a payment-method gate. Promo credits expire after 90 days; purchased credits never expire (§22).
- **SLA:** next-working-day dispatch, counted in working days excluding UK bank holidays. Daily cut-off time still to be set (§21).
- **Legal:** terms, privacy policy, and customer DPA already exist — need checking against the portal's actual sub-processors and retention behaviour (§21).
- **Enhanced Cover:** confirmed name. £5/£10/£20 ex-VAT for £500/£1,000/£2,000 cover, carrier declared-value passthrough, invoiced as a separate line. Never referred to as "insurance" in any customer-facing copy (§20).
- **Bulk offboarding:** CSV upload + multi-recipient builder, validated before creation, one bundle/one invoice/N orders, run async (§16).
- **Cancellations:** no refunds. Admin-only state with a reason code. Purchased credits are restored (not a refund — no money moves); **promo credits are forfeited** (§16, §22).
- **Inventory:** stock tracked per kit type, decremented on dispatch, checked during bulk validation. `kit_types` becomes a table so new kits don't need migrations (§16).
- **SMS notifications:** deferred. The `communication_log.channel` field keeps the SMS value so adding Twilio later is additive, but v1 is email only.
- **Support:** in-house KB + support forms + KB search, built on the same RLS/notification patterns as the rest of the portal — not a third-party helpdesk.
- **Order model:** flat — one order row per kit, tracking on the row, `bundle_id` for grouping (§4).
- **Credits:** typed per kit type — separate balances per `(company_id, kit_type)`, no cross-spending (§4, §5).
- **Guest orders:** not supported — `company_id` is NOT NULL everywhere, one tenant path per policy. One-off customers are served by staff-created manual orders (§10).
- **Company joining:** invites only. Signed single-use expiring tokens are the sole access grant; email domain is never consulted for authorization. Any email address works — no corporate-email requirement, no DNS verification (§3).

## 18. Still Open

Not blocking the first build phases, but each needs an answer before the phase that depends on it:

- **Pricing model.** Prices set (§20). Still open: per-company negotiated rates / volume tiers for enterprise clients, and whether shipping cost sits inside the kit price or as a separate line.
- **Daily dispatch cut-off time** — determines whether a late-Friday order ships Monday or Tuesday (§21).
- **Print Pack copy** — contents outlined in §21, but the actual wording needs drafting.
- **Screen inventory / UX** — no wireframes yet. Roughly: dashboard, new order, bulk order, order detail, addresses, employees, credits, invoices, support, settings, team — plus the admin app.
- **What happens after "Device Delivered."** Chain-of-custody is deferred, but the order lifecycle currently ends at delivery to you — which is where your actual service begins. Does the order close there, or does it need receipt-at-facility and completion states? Affects the `fulfilment_status` enum, so worth settling before phase 3.
- ~~**HubSpot integration scope.**~~ **Resolved — see §19.**
- ~~**Email deliverability.**~~ **Resolved — Resend confirmed as provider (§21). Domain verification and SPF/DKIM/DMARC are now the top pre-code task (§23).**
- **Error monitoring.** No tool chosen yet (Sentry is the default pick). Should be in place from phase 0, not added after the first production incident.
- **UI/UX design.** No wireframes or design system decided. The architecture doesn't depend on it, but the build does.
- **Who is building this, and on what timeline.** The architecture assumes competent full-stack execution across Postgres/RLS, Next.js, Stripe, and several third-party integrations. Worth stating plainly: this is a substantial build, and the security-critical parts (RLS policies, webhook signature verification, and invite-token handling) are the ones where inexperience is most expensive.

## 19. HubSpot — Scope

**Current state (checked directly against the account):** 3 contacts total, all created within the last few weeks, all manually entered (`hs_analytics_source: OFFLINE`), one of them a test record. No custom objects, no teams, no built-out pipeline, single core seat. HubSpot is a new, near-empty CRM used for inbound leads — not a system of record for anything, and nothing currently depends on it.

**Therefore: keep the integration deliberately small.** The temptation with a CRM is to mirror everything into it; resist that. The portal is the system of record (§1), and duplicating orders into HubSpot creates two sources of truth for data that only one system actually owns.

Recommended scope — one direction only, portal → HubSpot:

- **On company signup**: create/update a HubSpot Company and an associated Contact for the signing-up user, with `lifecyclestage` set appropriately (lead → customer on first paid order). This is the "new sign ups" use case and it's the one that earns its keep — it puts new accounts in front of you for sales follow-up without manual entry.
- **On first order**: flip the contact's lifecycle stage to `customer`. One property write, high signal.
- **Optionally, a timeline note** summarizing order activity per company (e.g. a monthly rollup, not per-order) so sales context exists without flooding the CRM with fulfillment noise.

Explicitly **not** recommended: a Deal per order (deals model a sales pipeline, not a fulfillment queue — 40 bulk offboarding orders would create 40 meaningless deals), mirroring invoices (Stripe and the portal already hold those), or two-way sync (nothing in HubSpot should be able to modify order data).

Implementation: this is a background job on the existing worker (§1) using a HubSpot private-app token in the secrets manager (§9), with failures retried and dead-lettered like any other outbound integration — a HubSpot outage must never block a signup or an order.

**Config issue worth fixing independently of the build:** the HubSpot account is set to **US/Eastern timezone and USD currency** while the business is UK-based (the account is on EU hosting, `app-eu1`). Any deal amounts, revenue reporting, or date-bucketed analytics will be wrong until that's corrected in HubSpot's account settings. Unrelated to the portal, but it'll silently corrupt reporting if left.

## 20. Pricing & Catalogue (current)

### Kit prices

| Kit type | Price (ex-VAT) | Inc VAT @20% | Status |
|---|---|---|---|
| Phone Kit | £40.00 | £48.00 | Active |
| Laptop Kit | £65.00 | £78.00 | Active |
| Monitor Kit | £85.00 | £102.00 | Active |
| Tablet Kit | *(TBC — was £50)* | — | Inactive |
| Accessories Kit | *(TBC — was £45)* | — | Inactive |

**Prices are stored ex-VAT as the single source of truth**; inc-VAT is computed at display and invoice time, never stored as an independent field. This is what prevents the drift documented in §21. Tablet and Accessories stay in `kit_types` flagged `active = false` — they can be switched back on without a migration.

**Display rule (confirmed): show ex-VAT prices, with VAT as its own line.** Consistently, everywhere:

- **Catalogue / kit selection** — "£65.00 ex VAT" (never a bare "£65", which is the ambiguity that caused the original bug).
- **Cart / checkout summary** — line items ex-VAT → Subtotal → VAT @ 20% → Total.
- **Invoice PDF** — same breakdown, plus your VAT registration number and a sequential invoice number, per UK VAT invoice requirements (§12).
- **Stripe** — charge the inc-VAT total, with VAT as a separate tax line so Stripe's records match your invoices. Stripe Tax can compute this rather than hardcoding 20%, which matters if a reduced or zero rate ever applies.

Round at the invoice total, not per line, and store amounts in integer pence rather than floats — `54.17` style values are exactly where rounding errors surface across a 40-order bulk invoice.

Worked example — kits and cover are both plain ex-VAT line items, with a single VAT line at the bottom:

```
Laptop Kit × 2                          £130.00
Phone Kit × 1                            £40.00
Enhanced Cover (up to £1,000) × 1        £10.00
                              ─────────────────
                        Subtotal (ex VAT) £180.00
                              VAT @ 20%    £36.00
                              ─────────────────
                                  Total   £216.00
```

No per-line VAT column, no inc-VAT prices shown alongside — one VAT line, one total. Same layout on screen at checkout and on the invoice PDF, so the customer sees the same numbers in both places.

⚠️ **Price-change check:** historically £65 was the *inc-VAT* price (the correct Base44 records show £54.17 ex → £65.00 inc). Treating £65 as ex-VAT means the customer now pays £78 — a 20% increase. Same for the other kits. Confirm this is intended rather than an artefact of fixing the VAT bug.

### Enhanced Cover (optional add-on) — confirmed name

| Cover level | Price (ex-VAT) | Inc VAT @20% |
|---|---|---|
| Up to £500 | £5.00 | £6.00 |
| Up to £1,000 | £10.00 | £12.00 |
| Up to £2,000 | £20.00 | £24.00 |

**Model: carrier declared-value passthrough.** The declared value is sent to Sendcloud at label purchase (§7) and claims are handled through the carrier. Chosen over self-insuring: underwriting £2,000 devices against £20 premiums means one lost laptop erases many sales, with no reserve behind it.

**Named "Enhanced Cover" throughout — never "insurance".** In the UK, selling insurance is an FCA-regulated activity, whereas offering enhanced liability as part of a carriage contract generally is not — which is why couriers say "compensation" and "cover". Apply this consistently in UI copy, invoice line items, emails, KB articles, and terms; a single stray "insurance" in customer-facing copy undoes the distinction. Still worth a solicitor's confirmation, since this is legal ground rather than architecture.

**Why cover carries 20% VAT (the naming and VAT decisions are linked).** These two can't be separated, and the trade only works one way:

| Framing | VAT | Other tax | Regulation |
|---|---|---|---|
| Genuine insurance | Exempt | Insurance Premium Tax @12% | FCA authorisation required |
| Enhanced Cover (part of carriage service) | **Standard-rated 20%** | — | Not FCA-regulated |

Because cover is positioned as enhanced liability within the carriage service rather than as an insurance product, it's a standard-rated supply. HMRC's composite/ancillary supply treatment points the same way: an add-on ancillary to a standard-rated principal supply generally takes that principal supply's VAT treatment. Making cover VAT-free would mean positioning it as actual insurance, which drags FCA authorisation and IPT back in — not a sensible trade for a £20 add-on.

**Design assumption: 20% VAT on cover, same as kits.** Confirm with your accountant before launch; the `cover_tiers` table carries its own `vat_rate` column so a different treatment is a data change, not a code change.

Data model:

- `cover_tiers` table: id, label, max_value, price_ex_vat, **vat_rate** (default 0.20), active — a table rather than hardcoded tiers, same reasoning as `kit_types`. The explicit `vat_rate` means an accountant's ruling changes data, not code.
- `orders.cover_tier_id` (nullable) plus `cover_price_ex_vat` snapshotted at creation, matching how kit price is handled.
- Cover appears as its **own invoice line item**, not folded into the kit price — required for a clean VAT breakdown and so customers can see what they bought.
- The declared value passes into `buyLabel()` via the shipping adapter (§7), so a provider swap doesn't break cover.
- **Margin check needed:** Sendcloud/DPD charge for declared value. Confirm £5/£10/£20 clears their cost at each tier before launch — currently unverified.
- **Claims flow is undesigned.** When a covered device is lost, someone has to file with the carrier, chase it, and tell the customer. Worth at least a "Claim" state and an admin action in the fulfillment section (§10) rather than handling it entirely over email.

## 21. Signup, SLA & Remaining Build Detail

### Company signup — self-serve

Anyone can sign up, create their company, and order. No approval gate. Flow:

1. Email + magic link → verified account
2. Create company (name, billing email, address, VAT number optional) → creator becomes `company_admin`
3. Land in an empty-state dashboard prompting the three first actions: add a return address, place an order, invite a teammate

Self-serve removes the friction that would otherwise gate growth, but it does mean unvetted accounts, so build these guards in from the start rather than after the first abuse:

- **The free-kit promo is the obvious abuse target** — see §23 for the full design.
- **Card-not-present fraud**: enforce Stripe Radar rules and 3DS on first payment.
- **Empty/abandoned companies** clutter admin views — a `status` on `companies` (already in §4) lets you filter dormant accounts out of operational screens.
- Every self-serve signup still flows to HubSpot (§19) so new accounts are visible for follow-up.

### SLA — next working day dispatch

Committed: **kits dispatched within 1 working day of order** (subject to stock, §16). This isn't just copy — it's the baseline the notification timings compute from:

- Dispatch-due timer starts at payment confirmation, counted in **working days** excluding weekends and UK bank holidays (§9).
- Missing the dispatch window flags the order internally *before* the customer notices — an internal escalation, distinct from the customer-facing nudges.
- `confirm_sent_checkin_due_at` and `confirm_received_checkin_due_at` are set relative to dispatch (or `leaver_last_day` where known, which is the better anchor for returns).
- Orders placed after a daily cut-off count from the next working day. **The cut-off time needs deciding** — it determines whether a 4pm Friday order dispatches Monday or Tuesday.
- Publish the SLA in the KB (§15) so it's a stated commitment rather than an implicit one.

### Legal & data protection

Terms, privacy policy, and customer-facing DPA all exist. Two things to verify rather than assume, since the portal changes the facts they describe:

- **The DPA needs to cover the actual sub-processor list** — Supabase, Vercel, Stripe, Sendcloud, Resend, and later BambooHR and whichever MDM vendors. If it predates these, it needs updating, and enterprise procurement will check.
- **Retention for leaver personal data.** You hold home addresses and personal emails of departing employees who never contracted with you directly — your customer is the controller, you're the processor. The retention period in the privacy policy has to match what the system actually does, which means building a deletion job, not just stating a policy.
- The no-refunds position (§16) needs to be in the terms and surfaced at checkout.

### Order & invoice numbering

**Order reference format (confirmed):** `[KIT_PREFIX]-[YYMMDD]-[SEQUENCE]`

| Prefix | Kit type |
|---|---|
| `RKL` | Laptop Kit |
| `RKT` | Tablet Kit |
| `RKP` | Phone Kit |
| `RKM` | Monitor Kit |
| `RKA` | Accessories Kit |

`YYMMDD` is the creation date; `SEQUENCE` is a 3-digit counter resetting daily **per prefix**. Example: `RKL-260807-001`. Bundles get a parallel `BND-[YYMMDD]-[SEQUENCE]` identifier; individual orders keep their own references and are linked by `bundle_id`.

Five implementation points, each a real failure mode rather than pedantry:

1. **Generation must be atomic.** A daily-resetting per-prefix counter can't use a plain Postgres sequence. Two concurrent orders will both read "last = 004" and both write `005` unless generation is transactional. Use a `reference_counters` table (prefix, date, last_value) with a single atomic statement:
   ```sql
   INSERT INTO reference_counters (prefix, ref_date, last_value)
   VALUES ($1, $2, 1)
   ON CONFLICT (prefix, ref_date)
   DO UPDATE SET last_value = reference_counters.last_value + 1
   RETURNING last_value;
   ```
   A bulk CSV upload creating 40 orders at once is exactly the scenario that exposes a non-atomic implementation.

2. **`YYMMDD` must be computed in Europe/London, not UTC.** During BST an order placed at 00:30 is 23:30 UTC the previous day — a UTC-derived date produces yesterday's stamp and can collide with an already-issued reference. Pin the date derivation to the business timezone (§9).

3. **Sequence overflow — decided: roll to four digits.** The sequence is zero-padded to 3 digits as standard (`001`), but past 999 it simply grows: `RKL-260807-1000`. It never wraps and never fails. Two consequences to build for from the start, since retrofitting them is worse than allowing for them now:
   - **Never parse references by fixed width or character offset.** Split on `-` and take the third segment. A regex like `^(RK[LTPMA]|BND)-(\d{6})-(\d{3,})$` handles both widths; `substring(11, 14)` silently breaks on the 1000th order.
   - **Store references as `varchar`, not `char(14)`**, and make sure any column width, CSV export, or PDF layout tolerates a longer string.

   Rejected alternatives: hard-failing means a bulk upload dies mid-batch on a busy day, and wrapping back to `001` would produce duplicate references — the one genuinely unrecoverable outcome, since references appear on printed Print Packs.

4. **References are immutable once assigned.** Admin has full order control (§10) including changing kit type — but the reference must never be regenerated, even if it then "wrongly" says `RKL` for what became a phone kit. The reference is on printed Print Packs, in customer emails, and quoted in support calls; a mutable identifier is worse than a slightly inaccurate one. Kit type is a separate, authoritative column.

5. **This format does reveal daily volume.** `RKL-260807-047` tells a customer you shipped 47 laptop kits that day. That's a deliberate trade for human-readable, support-friendly references — worth being aware of rather than surprised by. If it ever matters commercially, a non-sequential suffix is the fix.

**Invoice numbers are separate and follow different rules.** UK VAT invoices must be **strictly sequential with no gaps** — so a dedicated Postgres sequence, not this format. A cancelled invoice is *voided, not deleted*: deleting one leaves a gap and breaks compliance. Order references may freely have gaps (cancelled orders, abandoned checkouts); invoice numbers may not. Keeping the two schemes distinct is correct.

### Print Pack contents (to be specified)

The document the departing employee actually reads, so it carries real weight. At minimum: ReturnKits branding, the order reference, what's in the kit, step-by-step packing instructions, the pre-paid return label (or clear instructions to use the enclosed one), the courier and drop-off/collection details, what to do if something's wrong, and a support contact. Worth drafting the copy properly rather than treating it as a formatting exercise.

### Email — Resend

Provider confirmed: **Resend** (existing account). Free tier covers 3,000 emails/month, Pro is $20/mo beyond that — comfortably inside free tier at launch volume.

Setup requirements, all of which are launch blockers rather than nice-to-haves:

- **Verify `returnkits.com` as a sending domain in Resend** and publish the SPF, DKIM, and DMARC records it generates. Without these, Print Pack and nudge emails land in spam — which silently breaks the entire confirm/nudge loop the product depends on. This is the single highest-priority pre-code task.
- **Send from a subdomain** — `notifications@mail.returnkits.com` or similar — so transactional sending reputation is isolated from your ordinary business email. If a bulk send ever goes wrong, it doesn't poison the domain you use for actual correspondence.
- **Set a real `Reply-To`** (support inbox), not a no-reply address. Customers *will* reply to a "have you sent it back?" nudge, and those replies should reach someone.
- **Consume Resend's webhooks** (delivered, bounced, complained) and write the outcome back to `communication_log` (§13) — otherwise "sent" means "handed to Resend", not "arrived", and a bouncing address on a leaver return goes unnoticed until the kit is lost.
- **Suppress on hard bounce and complaint.** Repeatedly emailing a dead address damages sending reputation for every other customer.

**Templates: React Email** (`@react-email/components`), which Resend maintains. Templates live in the same repo, are type-checked against the data passed into them, and preview locally — meaningfully better than maintaining HTML in a dashboard, and it means a change to order data that breaks an email fails at build rather than at send.

Inventory — roughly 13, each needing copy and branding: magic-link sign-in, teammate invite, order confirmation (bundle-aware), kit dispatched, on its way back, "have you sent it?" check-in, "has it arrived?" check-in, delivered/complete, escalation to account owner, low credit balance, credit purchase receipt, support acknowledgement, support reply. Every send is gated by `notification_preferences` and logged to `communication_log` (§5, §13).

For the launch cut (§23) only four are strictly needed: order confirmation, kit dispatched, and the two check-ins.

### Engineering practices not yet specified

- **Testing** beyond the RLS suite: integration tests against Stripe and Sendcloud sandboxes especially — payments and label purchase are where silent failures cost real money. E2E coverage of the order flow.
- **Product analytics** (PostHog or similar) to see where users abandon the order flow. Distinct from the business analytics in §10.
- **Feature flags** for phased rollout, so bulk ordering or MDM can ship dark and be enabled per company.
- **Demo/seed data** for sales demos — Base44 had a demo account and it's worth keeping the pattern.

## 22. Free Kit Promo

Grants **1 Laptop Kit credit** to a company, redeemable later through the normal checkout flow (a credit adjustment, not an auto-created order — the right call, since it keeps one redemption path rather than two).

Carried over from Base44: `companies.free_kit_promo_claimed` (bool) and `companies.free_kit_promo_expires_at` (timestamp; absent means ineligible, which correctly excludes pre-feature companies).

### Fix the claim to be genuinely atomic

The Base44 implementation fetches the company, checks `claimed`, then writes `claimed = true` before inserting the credit. That ordering is a sensible fail-safe instinct, but it is **not atomic** — read-then-write across separate operations is a TOCTOU race, and two concurrent requests can both observe `claimed: false` before either writes. It also introduces a real failure mode: if the flag write succeeds and the ledger write then fails, the customer has burned the promo and received nothing, recoverable only by hand.

Postgres removes the trade-off entirely — one transaction, one conditional update:

```sql
BEGIN;
  UPDATE companies
     SET free_kit_promo_claimed = true
   WHERE id = $1
     AND free_kit_promo_claimed = false
     AND free_kit_promo_expires_at > now()
  RETURNING id;          -- 0 rows → already claimed, expired, or lost the race → abort
  INSERT INTO credit_ledger (company_id, kit_type_id, transaction_type, direction, quantity, notes)
  VALUES ($1, <laptop>, 'Adjustment', 'Credit', 1, 'Free kit signup promo');
COMMIT;
```

The `WHERE` clause and the write are a single statement, so the check can't be separated from the act; a losing concurrent request matches zero rows and aborts cleanly. Both writes commit together or neither does. Keep the existing HTTP semantics (409 already claimed, 410 expired) by distinguishing the two cases in a follow-up read when zero rows return.

### The guards don't cover the actual risk

Every existing guard is **per-company** — they stop one company claiming twice. With self-serve signup (§21), the real abuse is one *person* registering ten companies for ten free laptop kits, which is cross-company and entirely unguarded. Worth adding, roughly in order of value per unit of effort:

- **Verified email before the promo unlocks** — implicit in magic-link auth, but enforce it explicitly rather than assuming.
- **Block disposable-email domains** at signup — kills the cheapest attack.
- **Deduplicate on delivery address at redemption.** This is the highest-value guard and it's specific to selling physical goods: exploiting the promo requires receiving an actual box at an actual address, so several companies redeeming promo credits to the same delivery address is the real attack signature. Cheap to detect, needs no signup friction, and catches the realistic case rather than a theoretical one.
- **Soft signals for review, not hard blocks**: same billing address, similar company names, several signups from one IP in a short window. Flag in the admin dashboard (§10) rather than auto-rejecting — false positives on real customers cost more than the occasional free kit.

**Decided: do not require a saved payment method at signup.** It's the strongest cross-account signal (Stripe surfaces card-fingerprint reuse), but it's the wrong trade today. With a near-empty customer base, signups matter far more than abuse prevention, and a card gate on a free offer is the single biggest conversion killer available. The physical-fulfilment requirement is already a stronger natural rate limiter than any software gate — a fraudster must receive a real box at a real address. At current volume, abuse is visible by eye in the admin dashboard the day it happens. Keep the Stripe SetupIntent hook easy to add later; it's straightforward to introduce and disproportionately irritating to withdraw once real customers are used to signing up without it.

None of this needs to be airtight. It needs to cost more effort than a free laptop kit is worth.

### Credit expiry

**Promo-granted credits expire 90 days after grant. Purchased credits never expire.**

The distinction matters: purchased credits are money the customer already paid, and expiring them is both a bad look and a plausible unfair-terms argument even in B2B. Promo credits are a marketing grant and expiring them is normal, keeps the balance sheet honest, and stops unredeemed free kits accumulating indefinitely as an open liability.

- Add `expires_at` to `credit_ledger` entries (nullable — `NULL` means never expires, which is the default for `Purchase`).
- The rule keys off `transaction_type`: `Adjustment`/promo gets an expiry, `Purchase` doesn't.
- A scheduled job writes an offsetting debit entry when credits lapse — never mutate or delete the original row, consistent with the append-only ledger (§5).
- Reminder email at 14 days remaining, through the standard notification worker and preferences (§5).
- Build the `expires_at` column in phase 1 so no migration is needed later; the expiry job itself can land in phase 5 with the other scheduled work.

### Cancellation interaction — promo credits are forfeited

**A cancelled promo-paid order does not restore the credit.** The free kit is claimed once and spent once; cancelling forfeits it. This closes the cancel-and-rebook loop entirely rather than relying on expiry-date bookkeeping to contain it.

Note this is a deliberate exception to the general credit rule in §16, where cancelling a credit-paid order *does* restore the credit — that still holds for **purchased** credits, which are money the customer paid and shouldn't lose to a cancellation. The distinction is once again `transaction_type`: promo/`Adjustment` credits forfeit on cancellation, `Purchase` credits return.

Implementation: on cancellation, check whether the redeemed credit originated from a promo grant (via `credit_transaction_id` on the order → originating ledger entry). If promo, write no compensating entry and record the forfeit in the cancellation reason. If purchased, restore as normal.

Two things this needs to be fair rather than merely correct:

- **Say so at the point of cancellation.** "Cancelling this order will forfeit your free kit credit" before they confirm — not buried in terms. A customer who cancels a free-kit order by accident and silently loses it will contact support, and support will hand it back manually, which costs more than the warning.
- **Admin override exists anyway.** Staff can grant a replacement credit via a ledger `Adjustment` with a reason code (§10), so genuine cases are recoverable without weakening the default.

## 23. Priority — What To Build First

The main risk in this document is its own scope. It describes a large system; the business currently has effectively no customers. Building all of it before launch is the standard way to spend six months and learn nothing about what customers actually want.

### Blockers before any code (days, not weeks)

1. **Verify `returnkits.com` in Resend; publish SPF, DKIM, DMARC** (§21). Highest priority of anything here — undeliverable email breaks the confirm/nudge loop the product is built around.
2. **Open Sendcloud and Stripe accounts**, get test-mode credentials.
3. **Confirm the ex-VAT pricing decision** — £65 ex-VAT means customers now pay £78, a 20% rise on the historical inc-VAT £65 (§20).
4. **Pick error monitoring** (Sentry is the default) and wire it in phase 0, not after the first incident.

### The launchable core — build only this

Auth + company + RLS → single order creation → Stripe payment → Print Pack + label → order status with Confirm Sent/Received → basic admin fulfilment view → four emails (confirmation, dispatched, two check-ins).

That is a complete business: a customer orders a kit, pays, receives it, returns a device, and you can see and manage it.

Sequencing within that is not arbitrary. **RLS goes first** because everything sits on it and retrofitting tenant isolation is genuinely dangerous. **Payment comes before automation** because getting paid matters more than being efficient.

### Explicitly deferred

Bulk CSV ordering · inventory tracking · credits and the free-kit promo · Enhanced Cover · knowledge base · MDM · BambooHR · escalation and billback · HubSpot sync · API keys and webhooks · customer-facing analytics · SMS.

Two of these deserve a specific argument, because they look essential and aren't:

- **The Sendcloud API integration can wait.** At five orders a week, buying labels by hand in Sendcloud's own dashboard takes two minutes. The integration earns its place when manual label-buying becomes annoying — which is a real signal, not a guess. Build the `ShippingProvider` interface (§7) regardless, but the first implementation can be "staff pastes in a tracking number."
- **Credits are the most complex thing in the design** — typed per kit type, append-only ledger, expiry jobs, forfeit-on-cancel rules, reconciliation. If the free kit can launch as a simple checkout discount instead, all of that complexity waits until someone actually wants to prepay for kits.

### After launch, in this order

Whatever your first real customers ask for — that beats any roadmap written now. As a default ordering: bulk ordering when you land an enterprise client; Sendcloud automation when manual labels hurt; credits when someone wants to prepay; the KB when you've answered the same question five times; BambooHR when a client asks for HRIS-triggered retrieval.

The build phases in §8 remain the correct *dependency* ordering. This section is the *scope* decision layered on top: build phases 0–4 narrowly, launch, then let demand decide what comes next.

## 24. Pricing History — What Was in Base44

There is **no pricing model** in the existing app — no price list, product, or settings entity. Prices are hardcoded in application code and snapshotted onto each order at creation as `kit_price_ex_vat` / `kit_price_inc_vat`. Reading the 54 test orders back, prices were clearly being experimented with over July:

| Kit type | Prices seen | Most recent |
|---|---|---|
| Laptop Kit | 0, 29, 54.17, 65, 70, 75, 85 | **£65** |
| Phone Kit | 19, 40, 45 | **£45** |
| Accessories Kit | 45 | **£45** |
| Tablet Kit | 50 | **£50** |
| Monitor Kit | *(never ordered in test data)* | — |

### VAT handling is currently broken

This is the important finding. In the earliest test orders (10–11 July) the VAT maths is correct:

- £54.17 ex → £65.00 inc ✓ (54.17 × 1.2)
- £19.00 ex → £22.80 inc ✓
- £29.00 ex → £34.80 inc ✓

In everything after that, **`ex_vat` and `inc_vat` hold the identical value** — £65/£65, £45/£45, £70/£70. VAT is no longer being calculated at all. Whichever way that's read it's wrong: either customers are being charged £65 when they should pay £78, or £65 is VAT-inclusive and the ex-VAT figure on the invoice is overstated by 20%. Since UK VAT invoices must show a correct VAT breakdown (§12), this has to be fixed properly in the rebuild rather than carried over.

### Design implication

Confirms the §16 decision to make `kit_types` a real table rather than an enum:

- `kit_types`: id, name, active, **price_ex_vat**, vat_rate (default 0.20), stock_on_hand, low_stock_threshold, sort_order
- Store **ex-VAT only**; compute inc-VAT at display/invoice time. Storing both as independent fields is precisely what produced the drift above. Do still snapshot the computed figures onto the order at creation — an order must remember what was actually charged even after the price list changes.
- Price changes audit-logged so a historical invoice can be explained.

Per-company negotiated pricing and volume tiers don't exist in the current data. If enterprise clients will get bespoke rates, add a `company_kit_prices` override table (company_id, kit_type_id, price_ex_vat) checked before falling back to list price — worth writing the lookup that way from the start even if the override table stays empty initially.
