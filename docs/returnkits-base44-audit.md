# ReturnKits Base44 App — Technical Audit

**App:** ReturnKits (`69d4c9e86c3341cd1ccc0bd0`)
**Audited:** 7 August 2026
**Scope:** 13 entity schemas, RLS policies, and all production data (54 orders, 11 companies, 2 users, 4 credit transactions)

## What I could and couldn't examine

**Examined:** entity schemas, field definitions and enums, RLS policies, and every data record via the API.

**Not examined:** application and backend function source code — reading files requires a Base44 Builder plan. So this audits the *data layer and access control*, not the UI or business logic. That limitation is itself a finding (§4.4).

---

## 1. Critical — tenant isolation is applied inconsistently

The single most important finding. Your original brief stated: *"Role-Based Access: the portal enforces strict data isolation (via RLS), ensuring that a customer user can only view orders and invoices tied to their specific company."*

**That isn't what the policies do.** Of the six entities carrying a `company_id`, only half actually use it for access control:

| Entity | Read policy scoped by | Correct? |
|---|---|---|
| `Invoice` | `company_id` ✓ | ✅ |
| `Employee` | `company_id` ✓ | ✅ |
| `CommunicationLog` | `company_id` ✓ | ✅ |
| **`Order`** | `created_by_id` / `user_email` only | ❌ **no company scoping** |
| **`SavedAddress`** | `created_by_id` only | ❌ **has `company_id`, ignores it** |
| **`CreditTransaction`** | `actor_email` only | ❌ **has `company_id`, ignores it** |

The `Order` read policy is:

```json
{"$or": [
  {"created_by_id": "{{user.id}}"},
  {"data.user_email": "{{user.email}}"},
  {"user_condition": {"role": "admin"}}
]}
```

**Consequence:** a colleague invited to the same company **cannot see their company's orders** — only ones they personally created. Same for saved addresses and the credit ledger. Meanwhile they *can* see the company's invoices, because that policy is written differently.

This isn't a data leak — it's the opposite, an over-restriction — but it means **the multi-user company model does not work**, which is a core requirement of the portal. The `User.company_role` field is even annotated *"ahead of future multi-seat team support,"* confirming it was never completed. With only 2 users across 11 companies, this was never exercised in testing.

**Severity: critical.** The headline feature ("invite your internal teammates to manage orders") does not function.

---

## 2. Critical — declared constraints are not enforced

The schema declares enums. The data violates them.

| Field | Declared enum | Values actually present |
|---|---|---|
| `Order.status` | Awaiting Payment, Payment Failed, Payment Received, Processing, Packing Kit, Kit Dispatched, On its way back, Device In Transit, Device Delivered, Issue / Delayed, Complete | **`Cancelled`** (not in enum) |
| `Order.fulfilment_status` | New Order, Ready to Pack, Packed, Dispatched, Completed | **`Archived`** (not in enum) |

51 of 54 orders carry `fulfilment_status: "Archived"` — a value the schema says cannot exist. **The schema is documentation, not a constraint.** Application code wrote values the declared model prohibits, and nothing stopped it.

For a system where `status` drives billing, fulfilment, and notification logic, silently accepting undeclared states is a serious integrity weakness. In Postgres this is a `CHECK` constraint or an enum type, and the write simply fails.

---

## 3. High — no referential integrity

**11 companies exist. 2 users exist.**

Company records reference owners that don't exist:

- `Plugd` → `owner_user_id: 6a5fcde70d17f2f8623d478d` — no such user
- `TEchboy` → `owner_user_id: 6a5be0be7a5fdb07ec11b56d` — no such user
- `olllie` → `owner_user_id: 6a5a0c55188f6416ae89ffe1` — no such user

Nine of eleven companies point at orphaned user IDs. Similarly, several orders carry `company_id: null`, and the **only order that reached "Payment Received"** (`6a43baaf...`) has no `company_id` field at all — a completed, paid order belonging to no company.

Foreign keys aren't enforced, so deleting a user silently orphans their company, and orders can exist outside the tenancy model entirely. Postgres foreign key constraints make both impossible.

---

## 4. High — the free-kit abuse vector, demonstrated in your own data

I flagged this as theoretical earlier. Your data shows it already happening:

- **`hello@plugd.co.uk` owns three companies** — "Plugd" (×2) and "Plugd2", all on domain `plugd.co.uk`
- **`ollie@beeseenlabs.com` owns two** — "TEchboy" and "Ollie Company"
- **`ollietrif@gmail.com` / `ollietrif94@gmail.com`** own several more

Each company carries its own `free_kit_promo_claimed` flag, so each can claim a free Laptop Kit independently. One of the Plugd companies has already claimed one. This was your own testing rather than abuse — but it demonstrates the exact mechanism, with no guard triggered and nothing flagged.

At £65 of stock and postage per kit, this is a live commercial exposure the moment signups open.

---

## 5. High — `domain` values make auto-matching dangerous

Company domains in the data include:

- **`gmail.com`** — claimed by *two different companies* ("eGE" and "Demo")
- **`hotmail.co.uk`** — claimed by "olllie"
- `returnkits.com` — claimed by both "Demo" and "TEst COmpany"

The schema describes `domain` as *"used to auto-match employees to this company."* Had that matching been active, **every Gmail user signing up would have been auto-joined to one of those two companies** and been able to see their data. Two companies also both claim `returnkits.com` — your own domain — with no uniqueness constraint preventing it.

This validates the decision (§3 of the architecture doc) to remove domain-based joining entirely rather than trying to make it safe.

---

## 6. Medium — no transactions

Confirmed by the design of `claimFreeKit`, which marks the promo claimed *before* writing the credit specifically because both writes can't be wrapped in a transaction. Same exposure applies to credit redemption at checkout (create order + debit ledger).

The chosen ordering is a sensible fail-safe, but it means a partial failure leaves the customer having burned a promo with no credit to show for it — recoverable only by hand. It's also still racy: two concurrent requests can both read `claimed: false` before either writes.

**This is a money-correctness issue, not a future concern.**

---

## 7. Medium — data quality with no validation layer

Not all of this matters (much is test data), but it shows what passes unchallenged:

- **Invalid email accepted:** `itdept@bartlettgroup` — no TLD, on the only paid order
- **Tracking numbers unvalidated:** `111`, `11111`, `12345`, `s\egdWGRW\GH`
- **One tracking number across unrelated orders:** `1550 5170 231 664` appears on four separate bundles
- **Three representations of "no bundle":** `null`, `""`, and absent
- **Field misuse:** company "eGE" has `county: "LS17 8EE"` — a postcode in the county field
- **VAT broken:** `kit_price_ex_vat == kit_price_inc_vat` on 40+ records (see architecture §22)

The `null`/`""`/absent inconsistency is the one that bites hardest in code — every query filtering on `bundle_id` must handle three cases where there should be one.

---

## 8. Structural limitations (not bugs — platform boundaries)

These are the ones no amount of careful building fixes:

**No separate admin application.** Base44 is one app per project with data scoped to that app. A genuinely separate ops dashboard means either a second app with its own isolated entity store (which can't see your orders) or role-gated routes inside the customer app. This is the wall you hit.

**No execution-layer observability.** Retrying a failed job, pausing a queue, inspecting why a webhook didn't fire — these need visibility into the runtime that a managed builder doesn't expose.

**Vendor gating on your own code.** Reading your application's source requires a paid plan tier. Your access to code you wrote depends on someone else's pricing.

**Untestable access control.** RLS expressed as JSON policy config can't be systematically tested the way SQL policies can. There is no way to write an automated suite proving company A cannot read company B's data — which is precisely why the inconsistency in §1 went unnoticed.

---

## 9. What Base44 got right

Worth stating plainly, because the rebuild inherits it:

- **The data model is genuinely good.** Bundle grouping, the append-only credit ledger with `balance_after`, separating payment status from fulfilment status, timing nudges off `leaver_last_day` rather than a fixed timer, DB-backed API rate limiting that survives cold starts, and the customer-visible communication log — these are thoughtful designs that a from-scratch attempt would likely have missed.
- **Admin-only writes on `Order`.** All create/update/delete requires the admin role, forcing writes through backend functions where validation lives. Sound instinct.
- **Correct scoping on `Employee` and `CommunicationLog`**, including the `$nin: [null, ""]` null-guard pattern — which shows the right approach was understood, just applied unevenly.
- **It got you to a working product quickly**, which is what it's for.

---

## 10. Verdict

**The findings do not say "Base44 is a bad platform." They say Base44 does not enforce the guarantees this particular business needs.**

You are building a multi-tenant system that processes payments, holds a credit ledger representing real money, and stores the home addresses of people who never contracted with you. That combination requires four things:

| Requirement | Base44 | Postgres/Supabase |
|---|---|---|
| Enforced constraints (enums, FKs, uniqueness) | ❌ documentation only | ✅ database-enforced |
| Atomic multi-step writes | ❌ not available | ✅ transactions |
| Consistent, testable tenant isolation | ❌ inconsistent, untestable | ✅ RLS + automated test suite |
| Separate admin application | ❌ structurally unavailable | ✅ separate deployment, shared DB |

Every critical and high finding above traces back to one of those four gaps. They aren't mistakes in how the app was built — §9 shows the thinking was sound. They're the platform's boundaries showing through.

**Recommendation: proceed with the rebuild**, on the evidence rather than on principle. Three points reinforce the timing:

1. **The data model is validated and worth porting.** This isn't starting over — it's re-implementing a proven design on a foundation that enforces it.
2. **No real customer data exists.** All 54 orders are test records; the single "Payment Received" order has no company. Migration risk is effectively zero, and this is the cheapest this move will ever be.
3. **The bugs found here are fixed by the platform change itself, not by discipline.** Enum violations become impossible with `CHECK` constraints. Orphaned records become impossible with foreign keys. Inconsistent tenant scoping becomes detectable with an automated RLS suite. Partial credit writes become impossible with transactions.

**One thing to carry forward deliberately:** the §1 finding is the most important input to the new build. The customer-facing requirement is that *any* user in a company sees that company's orders, addresses, invoices, and credits. Write the cross-tenant RLS test suite to assert both directions — that company A cannot see company B's data, **and** that user 2 in company A *can* see user 1's orders. The second assertion is the one Base44 silently failed for a year.
