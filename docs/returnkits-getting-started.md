# ReturnKits Portal — Getting Started

Companion to `returnkits-portal-architecture.md` (the design) and `returnkits-implementation-plan.md` (the phase-by-phase build order — **follow that for sequencing**). This document is the mechanics: accounts, local tools, and how the repo is shaped.

> **Revised for the Lovable + Retool build.** An earlier version of this doc described a Turborepo monorepo with a hand-built ops app deployed to Vercel. That's no longer the plan — see `CLAUDE.md`. This version matches it.

---

## 1. The stack at a glance

### Services you pay for (or don't, at this volume)

| Service | Purpose | Cost at launch |
|---|---|---|
| **Supabase** | Postgres database, auth, file storage, background functions | $25/mo (Pro — needed for London region + backups) |
| **Stripe** | Payments | Per-transaction only (~1.5% + 20p UK cards) |
| **Sendcloud** | Shipping labels, tracking, pickups | Per-label |
| **Resend** | Transactional email | Free (3,000/mo) |
| **Sentry** | Error monitoring | Free tier |
| **GitHub** | Code hosting | Free (private repo) |
| **Lovable** | Customer portal UI, hosts `portal.returnkits.com` | From ~$25/mo |
| **Retool** | Ops dashboard | Free to 5 users |

Roughly **£50–70/month** to start.

### The code stack

| Layer | Tool | Why |
|---|---|---|
| Language | **TypeScript** | Type safety across DB → API → UI; catches whole classes of bug before runtime |
| Framework | **Next.js 15** (App Router) | React with server components and API routes |
| Structure | **Single app** — no monorepo | One Next.js app. Lovable builds the UI on top of it via two-way GitHub sync. There is no separate `apps/ops` — that's Retool, over the same Postgres. |
| Styling | **Tailwind CSS** + **shadcn/ui** | Utility CSS plus copy-in components you own |
| Database client | **@supabase/ssr** | Supabase client that handles auth cookies correctly in server components |
| Validation | **Zod** | One schema validates the form, the API, and the database write |
| Payments | **stripe** (Node SDK) | Checkout sessions and webhook verification — hand-written |
| Email | **Resend** + **React Email** | Templates as React components, in your repo, type-checked |
| PDF | **@react-pdf/renderer** | Print Packs as React components; runs serverless without a headless browser |
| Testing | **Vitest** | The RLS suite lives here. Never skip it. |
| Errors | **Sentry** | App plus background jobs |

### Repo shape

```
returnkits-portal/
├── app/                 → Next.js 15 App Router. Lovable builds most of this via two-way sync.
├── lib/
│   ├── core/            → business logic: orders, credits, pricing, references
│   ├── db/               → query helpers, generated Supabase types
│   └── permissions/      → can(user, action, resource) — every permission check goes through here
├── emails/               → React Email templates
├── supabase/
│   └── migrations/       → versioned SQL, checked into git, hand-written
└── package.json
```

`lib/core` and `lib/permissions` are the important ones — this is the logic Lovable's generated screens call into, rather than reimplementing. That's what stops the ops dashboard (Retool) becoming a second, subtly different set of order rules — Retool writes call your API, which calls this code.

---

## 2. Before you write code

### Accounts to create

1. **GitHub** — private repo, `returnkits-portal`.
2. **Supabase** — new project, **region: London (eu-west-2)**. Save the database password somewhere safe. Upgrade to Pro before launch (free tier pauses after a week of inactivity, and Pro is required for point-in-time recovery).
3. **Stripe** — UK entity, GBP. Stay in **test mode** throughout the build. Enable Stripe Tax for VAT.
4. **Sendcloud** — UK account, connect Royal Mail and DPD. Get test API credentials (not needed until Phase 6 — labels are bought manually in the dashboard until then).
5. **Resend** — verify `mail.returnkits.com` as a sending domain.
6. **Sentry** — free account, one project (`returnkits-portal`).
7. **Lovable** — workspace created; you'll create the actual project once the schema exists (Phase 2).
8. **Retool** — workspace created; you'll connect it to Postgres once there's data worth showing (Phase 4).

### DNS — do this first, it has lead time

Wherever `returnkits.com` is registered:

- Add the **SPF, DKIM, and DMARC** records Resend gives you after adding `mail.returnkits.com` as a sending domain. Propagation can take hours; verification blocks all email work.
- Lovable and Retool are both hosted SaaS — no CNAME setup needed for them to start. Add a custom domain later if you want `portal.returnkits.com` to point at Lovable's hosting.

### Local tools to install

| Tool | Why | Install |
|---|---|---|
| **Node.js 22 LTS** | Runtime | nodejs.org, or `winget install OpenJS.NodeJS.LTS` |
| **npm** or **pnpm** | Package manager | ships with Node, or `npm install -g pnpm` |
| **Git** | Version control | git-scm.com |
| **Docker Desktop** | Runs Supabase locally | docker.com |
| **Supabase CLI** | Migrations, type generation, local DB | `npm install -g supabase` |
| **VS Code** or **Cursor** | Editor (Cursor has AI built in) | code.visualstudio.com / cursor.com |
| **Claude Code** | AI pair programmer in your terminal | `npm install -g @anthropic-ai/claude-code` |

Verify everything:

```bash
node --version      # v22.x
git --version
docker --version
supabase --version
```

---

## 3. Step by step

Full phase-by-phase scope and exit criteria live in `returnkits-implementation-plan.md` — this section is just the setup mechanics for Phase 0–1.

### Step 1 — Create the repo

```bash
mkdir returnkits-portal && cd returnkits-portal
git init
npm init -y
git add -A && git commit -m "Initial commit"
```

Push to the GitHub repo you created above. No monorepo tooling, no second app to scaffold.

### Step 2 — Wire up Supabase

```bash
supabase init
supabase link --project-ref <your-project-ref>
supabase start          # local Postgres via Docker
```

Add to `.env.local`:

```
NEXT_PUBLIC_SUPABASE_URL=...
NEXT_PUBLIC_SUPABASE_ANON_KEY=...
SUPABASE_SERVICE_ROLE_KEY=...        # server-side only — never in NEXT_PUBLIC_*, never shipped to the browser
```

Retool holds its own separate privileged connection to Postgres — it doesn't use this key.

### Step 3 — First migration: companies, users, invites

```bash
supabase migration new initial_schema
```

Write the tables, then RLS policies, then the access token hook that puts `company_id` and `role` into the JWT. Apply and generate types:

```bash
supabase db reset                    # applies migrations to local DB
supabase gen types typescript --local > lib/db/types.ts
```

**This is the step to get right.** Everything else assumes tenant isolation works.

### Step 4 — Write the RLS test suite immediately

Before any UI. Vitest tests that create two companies, sign in as each, and assert that neither can read the other's rows — and that a second user in the *same* company can. Run against the local Supabase instance.

If these pass, your security model works. If you skip them, you'll find out from a customer.

### Step 5 — Point Lovable at the schema

Once companies/users/invites/RLS are in place (end of Phase 1), create the Lovable project and connect it to the same Supabase project. Let Lovable build signup, company creation, and invite acceptance on top of tables and policies that already exist — never the other way around.

### Step 6 — First vertical slice

`kit_types`, `reference_counters`, `orders` by hand; order form, Stripe Checkout, and the webhook handler. Order form and screens in Lovable, webhook hand-written and reviewed line by line.

**Get one order all the way through before building anything else.** Once that works, the architecture is proven and the rest is repetition.

### Step 7 — Retool ops view

Once real orders exist, connect Retool to Postgres: order list, mark dispatched, enter tracking, generate Print Pack. Reads hit Postgres directly; writes call your API.

### Step 8 — Emails

Resend + React Email. Four templates: order confirmation, dispatched, "have you sent it?", "has it arrived?".

Then you can launch.

---

## 4. A realistic note on who builds this

Lovable and Retool remove a meaningful amount of hand-coded UI work compared to the original all-custom plan — but the schema, RLS, webhooks, and money/concurrency logic are still real software development, not configuration.

Three honest paths:

**Build it yourself with AI assistance.** Very achievable, especially with Claude Code working in the repo. The architecture doc gives you specifications precise enough to implement against. Expect the hand-written core (Phases 0–1, and the payment logic in Phase 3) to take real focused time; the Lovable and Retool layers move faster since you're prompting against an existing schema rather than building UI from scratch.

**Hire a contract developer.** The architecture doc is close to a technical specification, which materially reduces cost and risk. A competent full-stack developer could deliver the launch scope faster than the original estimate, given how much of the UI layer is now generated rather than hand-built.

**Hybrid.** Have a developer build the foundation — schema, RLS, auth, payments — and take over the Lovable/Retool configuration yourself once the pattern is established.

Whichever you choose, the security-critical pieces deserve experienced eyes: RLS policies, webhook signature verification, and the payment and credit transactions. Those are the ones where a subtle mistake is invisible until it isn't.
