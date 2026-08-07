# ReturnKits Portal

Multi-tenant customer portal for ReturnKits, a UK IT asset recovery / reverse logistics business.

See `CLAUDE.md` for build rules and locked decisions, and `docs/` for the full design and implementation plan:

- `docs/returnkits-portal-architecture.md` — the design, with reasoning
- `docs/returnkits-implementation-plan.md` — phased build order and exit criteria (**follow this order**)
- `docs/returnkits-getting-started.md` — stack, tooling, setup commands
- `docs/returnkits-base44-audit.md` — what went wrong in the prototype this rebuild replaces

**Status:** Phase 2 — schema hand-written and RLS-tested (`companies`, `users`, `invites`, `audit_log`, `roles`, `kit_types`, `reference_counters`, `orders`, `bundles`, `addresses`, `employees`). Lovable screens built (signup, invite acceptance, order form/list/detail, addresses, employee directory).

**This repo holds the schema, migrations, and RLS tests only.** The customer portal UI is built in Lovable and lives in a separate repo, [ReturnKits/returnkit-portal-shell](https://github.com/ReturnKits/returnkit-portal-shell), synced two-way with Lovable. That repo's Supabase client points at the same hosted project as this repo's migrations — schema changes are still made here first, then reviewed, per CLAUDE.md.

## Quick start

```bash
npm install -g supabase
supabase init
supabase link --project-ref <project-ref>
supabase start
supabase db reset
```

See `docs/returnkits-getting-started.md` for the full setup walkthrough.
