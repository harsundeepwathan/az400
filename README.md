# JobPilot

A private, evidence-based **personal job-hunt operating system**: upload your resume once, save jobs you find,
get honest fit analysis that cites your own evidence, prepare tailored applications, track every application,
and see what is actually working.

> The product name lives in a handful of UI strings and `package.json`; search for "JobPilot" to rename it.

**Principles:** private by default · evidence-backed (every match cites a resume field or evidence item; anything
unsourced is marked *Needs confirmation*) · no fake ATS certainty · deterministic daily plan · honest analytics
with raw counts and small-sample warnings.

---

## Quick start (local, no external services)

Requirements: Node.js 20.9+ (22 recommended) and PostgreSQL 15+ (local binaries **or** Docker).

```bash
npm install
cp .env.example .env.local
# set SESSION_SECRET in .env.local, e.g.:  openssl rand -base64 36

npm run db:local:start      # starts Postgres on port 54329 (or: docker compose up -d db)
npm run db:migrate          # applies supabase/migrations (+ a local auth shim)
npm run db:seed             # optional: demo account with realistic data
npm run dev                 # http://localhost:3000
```

Demo account (after `db:seed`, local mode only): **demo@jobpilot.local / demo-password-123**.
`npm run db:reset` drops and recreates the local database, then re-seeds.

No AI key is needed: `AI_PROVIDER=mock` uses a deterministic offline engine, and every result it produces is
labelled **Demo output (mock AI)**.

## Commands

| Command | Purpose |
|---|---|
| `npm run dev` / `build` / `start` | Develop, build, serve |
| `npm run typecheck` | `tsc --noEmit` (strict) |
| `npm run lint` | ESLint (Next.js core-web-vitals + TypeScript rules) |
| `npm test` | Vitest unit tests + database integration tests (integration tests need `DATABASE_URL`) |
| `npm run test:e2e` | Playwright: builds, starts on port 3100, migrates + seeds, runs desktop and mobile projects |
| `npm run check` | typecheck + lint + tests |
| `npm run db:local:start` / `db:local:stop` | Disposable Postgres in `./.data/postgres` |
| `npm run db:migrate` | Apply pending migrations (tracked in `jobpilot_meta.migrations`) |
| `npm run db:seed` / `db:reset` | Demo data / reset local DB (refuses to run unless `AUTH_MODE=local`) |

For Playwright on a fresh machine run `npx playwright install chromium` once.

## Configuration

All configuration is environment variables (see `.env.example`); it is validated at startup by `src/lib/env.ts`.

| Variable | Notes |
|---|---|
| `AUTH_MODE` | `local` (default; credentials in the DB, signed cookie) or `supabase` |
| `DATABASE_URL` | Postgres connection string. For Supabase use the **session pooler** URL |
| `SESSION_SECRET` | ≥32 chars, required for `local` auth |
| `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Supabase mode |
| `SUPABASE_SERVICE_ROLE_KEY` | Server-only; used only to delete accounts. Never expose it |
| `STORAGE_MODE` | `local` (`./.data/uploads`) or `supabase`; defaults to `AUTH_MODE` |
| `AI_PROVIDER` | `mock` or `openai` |
| `AI_BASE_URL`, `AI_API_KEY`, `AI_MODEL` | Any OpenAI-compatible Chat Completions endpoint |
| `AI_JSON_MODE` | `json_schema` (structured outputs) or `json_object` for providers without schema support |
| `AI_TIMEOUT_MS`, `AI_MAX_RETRIES`, `AI_RATE_LIMIT_PER_HOUR` | Reliability and per-user cost limits |

### AI providers

The provider layer (`src/lib/ai`) is server-only. Each operation — requirement extraction, fit analysis,
application materials, interview prep — has a versioned prompt (`prompts.ts`), a Zod output schema
(`schemas.ts`), timeouts, exponential-backoff retries (429/5xx/malformed JSON) and metadata-only logging.

Whatever the provider returns is post-processed before anything is saved:

* citations must reference real records in the user's profile, otherwise the match becomes *unclear* and is
  flagged *Needs confirmation*; summary-only or unverified evidence is also flagged;
* the 0–100 score is recomputed deterministically from requirement coverage (must-haves 75%, nice-to-haves 25%);
* generated drafts are scanned for figures and job-description skills that do not appear in the profile;
* AI-extracted requirements must actually appear in the job description.

Users can switch AI assistance off in Settings; the local deterministic engine is then used and nothing is sent
to a provider. Contact details are never sent.

## Deploying (Supabase + any Node host)

1. Create a Supabase project. In Auth settings enable email/password and add `https://<your-app>/auth/callback`
   to the redirect URLs.
2. Set `AUTH_MODE=supabase`, `STORAGE_MODE=supabase`, the Supabase URL/anon key, `SUPABASE_SERVICE_ROLE_KEY`,
   `DATABASE_URL` (session pooler string) and `APP_URL`.
3. Apply migrations: `npm run db:migrate` with those variables (or `supabase db push`). The storage migration
   creates the private `resumes` bucket and its owner-only policy. The local auth shim is **not** applied in
   Supabase mode.
4. Deploy with `npm run build && npm run start` on Vercel, Fly, Render or a container. Keep secrets in the
   host's secret store.

The app connects to Postgres as the database owner and switches to the `authenticated` role inside each
transaction, so RLS policies apply exactly as they do for Supabase's own API.

## Architecture

```
src/
  app/                    Routes (App Router). (auth) sign-in/up · (setup) onboarding · (app) authenticated pages
    */actions.ts          Server Actions: auth check → Zod validation → data layer → revalidate
    api/export            JSON export of the user's data
    print/                Printable resume versions (browser "Save as PDF")
  components/             UI primitives (ui/) and feature components
  lib/
    db.ts                 pg pool; withUser() runs every query under RLS as the signed-in user
    auth/                 local (scrypt + JWT cookie) and Supabase implementations behind one API
    data/                 SQL data access, always scoped by user id
    resume/               file validation, text extraction (unpdf, mammoth), deterministic parser
    fit/                  requirement extraction, source catalogue, heuristic matcher, finalizeFit (enforcement + scoring)
    ai/                   provider interface, mock + OpenAI-compatible providers, prompts, post-processing
    claims.ts             unsupported-claim detection
    applications/stages.ts  pure stage-transition planner (events + reminders)
    today.ts, analytics.ts  pure, deterministic daily plan and analytics
  proxy.ts                optimistic route protection + Supabase session refresh
supabase/migrations/      schema, RLS, grants, storage policies
db/local-bootstrap.sql    local stand-in for Supabase's auth schema/roles
scripts/                  migrate, seed, local Postgres helper
tests/unit, tests/integration, tests/e2e
docs/PLAN.md, docs/THREAT_MODEL.md
```

**Data model** (all tables user-owned with RLS): `profiles`, `user_settings`, `target_roles`, `resumes`,
`employment_entries`, `education_entries`, `certifications`, `skills`, `projects`, `evidence_items`,
`resume_versions`, `jobs`, `job_requirements`, `fit_analyses`, `fit_matches`, `applications`,
`application_events` (append-only; drives analytics), `contacts`, `interviews`, `tasks` (reminders),
`generated_documents`, `ai_requests` (rate-limit metadata).

**Reminders** are created deterministically: moving to *Applied* schedules a follow-up (per your follow-up
setting), a recruiter screen schedules a "confirm next steps" reminder, scheduling an interview creates a prep
reminder for the day before, a closing date creates an application-deadline reminder, and an offer deadline
creates a decision reminder. Closing an application completes its automatic reminders.

## Security and privacy

See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md). In short: RLS on every table plus server-side checks,
composite foreign keys against cross-user references, magic-byte file validation, Zod validation on every input,
React output encoding, Server Actions (origin-checked), rate limits on sign-in and AI, export-my-data and
delete-account, secrets only in environment variables, and no sensitive content in logs.

## Known limitations

* The resume parser is heuristic. Unusual layouts, multi-column PDFs and scanned (image-only) files need manual
  correction or pasted text; there is no OCR.
* The mock provider produces template-based drafts; configure an AI provider for richer wording.
* Supabase mode is implemented against the documented `@supabase/ssr` APIs but was verified here only through
  type checking. The automated suite runs in local mode (plain PostgreSQL with the same migrations and RLS).
* Reminders are in-app only (no email or push).
* Unsupported-claim detection catches figures and job-description skills, not every paraphrased claim.
* Resume "PDF export" uses the browser's print dialog.
* Sign-in rate limiting is in-memory (per instance) in local mode.
* No Content-Security-Policy header yet.

## Post-MVP backlog

1. Email/push reminders and a weekly digest.
2. OCR for scanned resumes and optional AI-assisted resume structuring with the same verbatim checks.
3. CSP with nonces; shared rate-limit store.
4. Server-side PDF generation for resume versions and cover letters.
5. Browser extension or share-sheet capture of job postings (still user-initiated; no scraping).
6. Calendar (ICS) export for interviews and deadlines.
7. Evidence suggestions from interview reflections.
