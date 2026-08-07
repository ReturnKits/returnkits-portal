# ReturnKits Portal — Implementation Plan

**Revised for the Lovable + Retool build approach.** The architecture decisions in `returnkits-portal-architecture.md` all still hold — what changes is who builds each layer and how long it takes.

Companion to `returnkits-portal-architecture.md` (the design) and `returnkits-getting-started.md` (the setup).

---

## The approach

| Layer | Built with | Why |
|---|---|---|
| **Database, RLS, tests** | Hand-written SQL (Claude Code) | 20% of the work, 80% of the risk. Never delegated to a generator. |
| **Customer portal** | Lovable | Real React/TypeScript, two-way GitHub sync, native Supabase. You own the code. |
| **Ops dashboard** | Retool | Free to 5 users. Built for exactly this. Removes ~2 weeks of work. |
| **Money paths & webhooks** | Reviewed by hand | Generated code is fine for screens, not for idempotency and transactions. |

**Structure is now one app, not a monorepo.** No Turborepo, no `packages/*`, no second deployment. Business logic lives in `lib/` inside the single Next.js app.

### The rule that makes this safe

> **You own the schema. Lovable builds on top of it. The RLS suite is the gate.**

Create the database and its policies *first*, then point Lovable at the existing Supabase project. If you let Lovable design the schema, it will generate permissive RLS that looks correct — the logged-in user sees their own data — without cross-tenant rigour. That is exactly the bug class the Base44 audit found (`returnkits-base44-audit.md` §1), and it hid for months.

Run the RLS suite after **anything** Lovable changes. Red suite, nothing ships.

---

# PART 1 — THE LAUNCH BUILD

---

## Phase 0 — Foundations
**Effort: 1–2 days** (plus DNS propagation)

Start DNS and accounts on day one — they have lead time and block Phase 4.

- Accounts: Supabase (**London region**), Stripe (UK, test mode), Sendcloud, Resend, Sentry, GitHub, Lovable, Retool
- Resend: verify `mail.returnkits.com`, publish SPF/DKIM/DMARC
- Supabase CLI + Docker locally, migrations directory, git repo

**Exit criteria**
- ✅ `supabase db reset` rebuilds the local database from migrations
- ✅ Resend reports the sending domain verified
- ✅ Supabase project confirmed in London (`eu-west-2`)

> No app deployment step now — Lovable hosts the portal and Retool is SaaS. That removes the whole Vercel setup from this phase.

---

## Phase 1 — Database & tenancy *(hand-written, non-negotiable)*
**Effort: 4–6 days.** The most important phase. Do not shortcut it, and do not let a generator near it.

- Schema: `companies`, `users`, `invites`, `audit_log`, `roles`
- Supabase Auth magic link
- **Custom access token hook** injecting `company_id` and `role` into the JWT (§9.4)
- RLS policies with explicit `IS NOT NULL` guards (§3)
- **RLS test suite asserting all four directions** (§9.3)
- `CHECK` constraints on every enum, FKs on every relation, `NOT NULL` on `company_id`

**Exit criteria**
- ✅ Isolation: company A cannot read company B's rows
- ✅ **Collaboration: user 2 in company A CAN read user 1's rows** ← Base44 failed this
- ✅ Admin override: internal role reads across companies
- ✅ Null-claim guard: a user with no `company_id` reads **zero** rows
- ✅ Invalid enum values rejected **by the database**
- ✅ Suite runs in CI and fails the build when red

---

## Phase 2 — Core schema & portal screens
**Effort: 6–9 days** (schema by hand ~2 days, screens in Lovable ~4–7)

**By hand first:**
- `kit_types` (Laptop £65, Phone £40, Monitor £85 ex-VAT; Tablet/Accessories inactive)
- `reference_counters` + atomic reference function — `RKL-260807-001`, Europe/London, rolls past 999 (§21)
- `orders`, `bundles`, `addresses`, `employees` with RLS and both test directions

**Then in Lovable:**
- Signup, company creation, invite acceptance
- Order form, order list, order detail
- Saved addresses, employee directory

**Exit criteria**
- ✅ Two concurrent orders get **different** references (test explicitly)
- ✅ A colleague sees the order
- ✅ RLS suite still green after Lovable's changes
- ✅ Orders cannot be created without `company_id`

---

## Phase 3 — Payments *(generated screens, hand-reviewed logic)*
**Effort: 5–8 days.** Budget more than feels necessary.

- Lovable: checkout screens, invoice list, invoice detail
- **By hand: the Stripe webhook handler** — signature-verified, idempotent on Stripe's event ID (§9.7)
- `invoices` with a gapless sequential number from a dedicated Postgres sequence (§21)
- VAT: ex-VAT stored, inc-VAT computed, integer pence, VAT as a separate line (§20)
- Invoice PDF with VAT number and correct breakdown

**Exit criteria**
- ✅ Order → Stripe test checkout → webhook → marked paid
- ✅ **Replaying the same webhook event twice changes nothing**
- ✅ Wrongly-signed webhook rejected
- ✅ Invoice arithmetic correct to the penny
- ✅ Invoice numbers strictly sequential, no gaps

> Have Lovable build the screens. Read the webhook handler yourself, line by line. Double-granted credits and double-charges both live here.

---

## Phase 4 — Ops dashboard *(Retool)*
**Effort: 3–5 days.** Was 6–9 hand-built.

- Retool connected to Supabase Postgres
- Order list with filters (status, company, date)
- Mark dispatched, enter carrier and tracking
- Manual order creation on behalf of a company (`source: internal_staff`)
- Print Pack PDF generation triggered from Retool
- Customer-side status timeline + Confirm Sent/Received (Lovable)

**Two rules for Retool:**
1. **Reads may hit Postgres directly. Writes call your API.** Cancelling an order or adjusting credits must run through your app's logic, not a Retool button reimplementing the rules — otherwise you've recreated the "two implementations of order rules" problem the architecture exists to prevent.
2. **Retool bypasses RLS** via its privileged connection. Audit logging therefore happens in your API or via database triggers, never in Retool.

**Exit criteria**
- ✅ Staff dispatch an order; customer sees the change
- ✅ Print Pack generates correctly, served via a signed expiring URL
- ✅ Confirm Sent/Received records actor and timestamp
- ✅ Every ops write appears in `audit_log`

> Labels are still bought **manually in Sendcloud's dashboard**. Two minutes per order, zero build time.

---

## Phase 5 — Notifications
**Effort: 4–6 days**

- Resend + React Email: order confirmation (bundle-aware), dispatched, "have you sent it?", "has it arrived?"
- `communication_log` + Resend delivery webhooks (delivered, bounced, complained)
- Supabase Edge Function + `pg_cron` for scheduled check-ins
- **Working-day calculations** excluding UK bank holidays; sending-hours window
- **Dedupe keys** so retries don't double-send

**Exit criteria**
- ✅ One confirmation per order, including multi-item bundles
- ✅ Check-ins fire in working days, within sending hours
- ✅ Retrying a job sends nothing further
- ✅ Bounces recorded and suppressed
- ✅ Delivered to inbox across Gmail, Outlook, and a corporate domain

---

## 🚀 LAUNCH GATE

- [ ] All Phase 0–5 exit criteria pass
- [ ] RLS suite green
- [ ] Stripe live keys; a real £1 transaction end-to-end, then refunded
- [ ] Terms, privacy policy, DPA published and linked at checkout
- [ ] No-refunds policy visible before payment
- [ ] Sub-processor list matches reality (Supabase, Lovable, Retool, Stripe, Sendcloud, Resend)
- [ ] Sentry alerting somewhere you'll see it
- [ ] Supabase Pro enabled, point-in-time recovery active
- [ ] **Restore from backup rehearsed once**, before you need it
- [ ] You have personally placed, paid for, dispatched, and completed an order

**Revised total: 23–36 working days (~5–7 weeks)** — down from 27–41, with a lot of the remaining work being prompting rather than hand-coding.

---

# PART 2 — POST-LAUNCH

Demand-driven. This ordering is a default, not a commitment.

**Phase 6 — Shipping automation** *(when manual labels get annoying)* · 4–6 days
`ShippingProvider` interface + Sendcloud adapter. Label purchase, address validation, tracking webhooks normalised to your own status enum, exception auto-flagging.

**Phase 7 — Ops control plane** · 2–4 days *(was 6–10)*
Job retry/pause views, analytics dashboards. Mostly Retool configuration now rather than a build.

**Phase 8 — Credits & free-kit promo** · 5–8 days
Typed-per-kit ledger, **atomic promo claim** (§22), Stripe credit purchase, 90-day promo expiry, forfeit-on-cancel, reconciliation job.
*Exit: concurrent double-claim attempts grant exactly one credit.* Write this by hand.

**Phase 9 — Bulk ordering & inventory** · 7–10 days
CSV upload with per-row validation preview, async batch processing, partial-failure handling, `stock_movements`, low-stock alerts (§16).

**Phase 10 — Enhanced Cover** · 3–4 days
`cover_tiers`, declared value to Sendcloud, separate invoice line, claims state (§20).

**Phase 11 — Support** · 4–6 days
KB articles (public), support forms scoped by company and order, Postgres full-text search (§15).

**Phase 12 — Escalation & billback** · 4–6 days
Working-day thresholds, account-owner notification, escalated filter, admin-triggered charge (§14).

**Phase 13 — Integrations** · 10–15 days
API keys with DB-backed rate limiting, outbound webhooks with retry/dead-lettering, HubSpot signup sync (§19), MDM adapters, BambooHR marketplace app.
> Start the BambooHR partner application **early** — their review has its own timeline.

**Phase 14 — Self-service pickup** · 4–6 days
Request queue first; Sendcloud API booking for DPD/Evri constrained to same/next working day; Royal Mail falls back to staff (§14).

---

# Standing rules

**Never ship with a red RLS suite.** The one test protecting against the failure you can't recover from.

**Hand-write anything touching money or concurrency.** Webhooks, credit transactions, reference generation, promo claims. Generated code is fine for screens.

**You own the schema.** Lovable builds on it. Review every migration it proposes before applying.

**Every third-party webhook is signature-verified and idempotent.** From the first one.

**Ex-VAT stored, inc-VAT computed, integer pence.** The Base44 VAT drift came from storing both.

**Retool writes go through your API**, not straight to tables.

**Deferred is not cancelled.** Everything in Part 2 is designed for in the architecture doc — the schema accommodates it, so adding it later is additive.
