# JobPilot MVP — implementation plan

Scope is deliberately narrow: a private, single-user-per-account job-search tool. No scraping,
mass applying, marketplaces, payments, social features or native apps.

## Decisions

| Area | Decision | Why |
|---|---|---|
| Framework | Next.js 16 (App Router, Server Actions, `proxy.ts`), React 19, TypeScript strict | Current stable; server-first data access keeps secrets and AI calls off the client |
| Styling | Tailwind CSS 4 with small hand-written accessible components (shadcn-style) | No registry download needed; full control over focus, ARIA and states |
| Data | PostgreSQL via `pg`, one migration set in `supabase/migrations` | Same SQL runs on Supabase and on plain Postgres |
| Isolation | Every user query runs in a transaction as role `authenticated` with the user id in `request.jwt.claims` (exactly how Supabase PostgREST works), so **RLS applies to every statement**; queries also filter by `user_id` | Defence in depth; identical behaviour locally and on Supabase |
| Cross-user FKs | Child tables use composite `(id, user_id)` foreign keys | FK checks bypass RLS; composite keys stop attaching rows to another user's records |
| Auth | `AUTH_MODE=supabase` (Supabase Auth via `@supabase/ssr`) or `AUTH_MODE=local` (scrypt + signed HTTP-only cookie) | Local mode makes the app, demo and tests run with no external services |
| Files | Supabase Storage (private bucket, per-user folder policy) or `./.data/uploads` | Same abstraction, never public |
| AI | Provider interface; `mock` (deterministic, offline) and `openai` (any OpenAI-compatible Chat Completions API with JSON schema output) | Works without a key; swappable |
| Trust | AI output is validated with Zod, every citation is checked against the user's own records, scores are recomputed deterministically | The model can suggest but never assert unsupported facts |
| Daily plan | Pure function over dates and application state | AI never controls scheduling |
| Analytics | Pure functions over the append-only `application_events` log, with sample-size flags | Accurate, explainable numbers |

## Milestones (all implemented)

1. Scaffold, config, schema + RLS migrations, local Postgres bootstrap, migration runner.
2. Auth (local + Supabase), protected routes, onboarding.
3. Resume upload/paste → deterministic parser → editable preview → normalised storage; resume versions + printable view.
4. Evidence vault (manual + import from resume achievements, verification states).
5. Jobs, requirement extraction/editing, evidence-based fit analysis with source enforcement.
6. Application workspace: materials drafting with unsupported-claim checks, checklist, evidence selection, contacts, interviews, reminders.
7. Tracker: Kanban (drag-and-drop + keyboard + select fallback) and list views, stage events, automatic reminders.
8. Today dashboard, interview prep, analytics, settings (export, delete account, AI opt-out).
9. Seed/demo data, unit + integration + Playwright tests, docs.
