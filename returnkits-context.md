# ReturnKits — Context Primer

*Drop this file into another Cowork project's context when that project needs to know what ReturnKits is, without needing the full engineering history.*

## What it is

ReturnKits is a UK IT asset recovery / reverse logistics business. Companies use it to manage the physical hardware side of employee onboarding and offboarding: shipping a "kit" (packaging + instructions + a prepaid return label) to a new starter so they can send back old equipment, or to a leaver so they can post back their laptop, phone, or monitor. ReturnKits handles fulfilment, shipping, and tracking; the client company just tells it who needs a kit and where.

## Who uses it

B2B customers — any company with employees joining or leaving who need IT equipment collected or redeployed. Customers range from small teams to enterprise accounts (with volume-tiered credit pricing). There's a self-serve signup flow (no card required, no sales call needed), plus an "Enterprise pricing" toggle for higher-volume customers.

## How the core flow works

1. A company admin (or team member) signs up, or an existing admin adds an employee to a directory (or enters recipient details manually for a one-off).
2. They place an order specifying: kit type (Laptop/Phone/Monitor — Tablet and Accessories exist but are inactive), service type (`ship_to_new_employee` or `return`), the recipient, and optionally Enhanced Cover (declared-value protection, never called "insurance" for FCA reasons).
3. Payment is by card (Stripe) or prepaid credits (bought in bulk per kit type, redeemed 1:1, no cross-type substitution).
4. Once paid, ReturnKits staff dispatch the kit — currently a manual step in Sendcloud's dashboard (label purchase isn't automated), but tracking is fully automated via Sendcloud webhooks + an hourly polling fallback.
5. The recipient (new starter or leaver) receives the kit. For return orders, it now ships via Royal Mail with a prepaid return label already inside — the default action is drop it off anywhere, with an optional 30p self-booked home collection via a QR code on the box (ReturnKits has no visibility into whether that QR code gets used).
6. Automated reminders chase an outstanding return, escalating in tone over three tiers, sent primarily to the actual device-holder (the employee) rather than the company admin, so the admin isn't bombarded with emails they can't act on directly.
7. Sendcloud's "delivered" tracking event auto-completes the order — no manual "confirm received" step needed once real tracking data exists.

## Two separate applications, one database

- **Customer-facing portal** (built in Lovable, real React/TypeScript): where company admins and team members sign up, place orders, manage their employee directory, buy credits, view invoices, and manage settings.
- **Internal ops dashboard** (built in Retool): where ReturnKits staff view/manage all orders and companies across every tenant, mark orders paid/dispatched, correct tracking, flag cover claims, and cancel orders.

Both sit on the same Supabase Postgres database (London region) and the same set of hand-written RPCs/Edge Functions — nothing is duplicated business logic between the two UIs. Multi-tenant isolation is enforced by Postgres Row-Level Security, not application code.

## Pricing model

- Ex-VAT kit prices: Laptop £65, Phone £40, Monitor £85. ReturnKits is **not VAT-registered**, so no VAT is charged or shown anywhere in the product.
- Enhanced Cover: £5/£10/£20 for £500/£1,000/£2,000 of carrier declared-value protection, added per order.
- Prepaid credits: buy a batch of kit-type-specific credits by card, redeem them one at a time against future orders instead of paying per-order.
- Enterprise pricing: a per-company toggle that prices Laptop credits on a volume-tiered scale (which also bundles free Enhanced Cover into the price) — the incentive is protection at volume, not a cheaper kit.
- No refunds are ever automated. Cancellations before dispatch are supported in-app; any refund owed after that is a manual action a human takes directly in Stripe.

## Integrations

- **Stripe** — checkout, credit purchases, live since August 2026.
- **Sendcloud** — shipping labels (bought manually by staff) and tracking (fully automated: webhook + hourly poll fallback).
- **Resend** — all transactional email (order confirmation, dispatch, tracking/return reminders).
- **HubSpot** — new self-serve signups sync automatically as a linked Contact + Company, tagged with a "Sign-up" lead status, plus an internal notification email to ReturnKits staff.

## Notable product decisions worth knowing if you're building something adjacent

- Employees/recipients never get portal accounts or logins — they're a passive directory entry that receives kits and light nudge emails, nothing more.
- A company's own domain is treated as unverified, cosmetic metadata — never used to authorize access or joining. Company membership is invite-only via signed tokens.
- Money is always stored as integer pence, prices ex-VAT, to avoid the rounding/display drift bugs a prior prototype had.

## Status

Live in production. Real customers, real Stripe payments. Actively iterating on both the customer portal and the ops dashboard based on direct staff/customer feedback — this file describes the durable shape of the business, not a finished feature list (that level of detail lives in the codebase's own `CLAUDE.md`).
