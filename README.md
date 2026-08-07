# ReturnKits Portal

Multi-tenant customer portal for ReturnKits, a UK IT asset recovery / reverse logistics business.

See `CLAUDE.md` for build rules and locked decisions, and `docs/` for the full design and implementation plan:

- `docs/returnkits-portal-architecture.md` — the design, with reasoning
- `docs/returnkits-implementation-plan.md` — phased build order and exit criteria (**follow this order**)
- `docs/returnkits-getting-started.md` — stack, tooling, setup commands
- `docs/returnkits-base44-audit.md` — what went wrong in the prototype this rebuild replaces

**Status:** Phase 0 — Foundations.

## Quick start

```bash
npm install -g supabase
supabase init
supabase link --project-ref <project-ref>
supabase start
supabase db reset
```

See `docs/returnkits-getting-started.md` for the full setup walkthrough.
