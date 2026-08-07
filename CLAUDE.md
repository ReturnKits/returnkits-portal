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

## Build order

Phases 0–5 are the launch build (~5–7 weeks); everything after is demand-driven. **Do not build ahead.** Deferred at launch: bulk CSV ordering, inventory, credits/promo, Enhanced Cover, KB, MDM, BambooHR, escalation, HubSpot sync, API keys, SMS.

Labels are bought **manually in Sendcloud's dashboard** until Phase 6. Deliberate — two minutes per order at launch volume, zero build time.

Current phase: **0 — Foundations**.

## Gotchas from the prototype

- Base44 declared enums but didn't enforce them — 51 of 54 orders held a status the schema prohibited. Use `CHECK` constraints and Zod at every boundary.
- No foreign keys meant 9 of 11 companies referenced users that didn't exist. Add FKs on every relation.
- No transactions meant the free-kit claim marked itself claimed *before* granting the credit. In Postgres, use one transaction with a conditional `UPDATE ... WHERE claimed = false RETURNING`.
- Two companies both claimed `gmail.com` as their domain. This is why domain-based joining was removed entirely.

## Environment

Secrets in Supabase Vault, never plain DB columns or committed config. Stripe and Sendcloud stay in test mode until the launch gate. Supabase project region must be **London (eu-west-2)**.
