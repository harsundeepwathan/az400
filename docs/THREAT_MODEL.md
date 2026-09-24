# Threat model (MVP)

Assets: resume contents and contact details, employment history, job-search activity (companies,
salaries, rejection reasons, notes), uploaded files, AI-generated drafts, account credentials.

Actors: the account owner; another signed-in user; an unauthenticated attacker; the author of a
job description the user pastes; the AI provider.

| # | Threat | Mitigations in this codebase | Residual risk |
|---|---|---|---|
| 1 | **Cross-user access / IDOR** — user B requests user A's job, application or file by id | Every page, action and route handler resolves the user server-side (`requireUser`); every query runs as `authenticated` with RLS policies `user_id = auth.uid()` **and** filters by `user_id`; composite `(id, user_id)` foreign keys prevent attaching rows to another user's parent; ids validated as UUIDs; storage keys are `<userId>/<uuid>` and checked before deletion; Supabase bucket policy restricts to the owner's folder. Covered by `tests/integration/authorization.test.ts` and the E2E cross-account check. | Privileged paths (`withAdmin`) exist only for local sign-in/sign-up and account deletion. |
| 2 | **Resume data exposure** | Private by default; contact details are never sent to AI providers (`buildSources` excludes them); no resume text in logs (AI logging is metadata only); export limited to the user's rows via RLS; delete-account removes files then cascades all rows; `robots: noindex`. | Data at rest relies on the database/storage provider's encryption. |
| 3 | **Malicious uploads** | 5 MB limit (also enforced by server-action body limit); extension **and** magic-byte check (PDF `%PDF`, DOCX `PK`); legacy `.doc` rejected; parsing in-process with a timeout; files stored under random names, never served back or executed; original filename only stored as metadata. | Parser libraries (`unpdf`, `mammoth`) could have vulnerabilities; keep dependencies updated. No antivirus scanning. |
| 4 | **Prompt injection via job descriptions or resumes** | All user content is wrapped in `<untrusted_*>` tags that content cannot close; the system prompt forbids following embedded instructions; outputs must match a Zod schema; every citation must reference a real record or is downgraded to "Needs confirmation"; the score is recomputed deterministically; generated text is scanned for figures/skills absent from the profile; instruction-like text in a job description is flagged in the UI. | A model can still produce persuasive but unhelpful wording; the user reviews every draft. |
| 5 | **Fabricated qualifications** | See 4; bullet rewrites are checked against their own original bullet; STAR stories only use verified evidence, with facts copied from the vault. | Heuristic claim detection can miss paraphrased claims. |
| 6 | **Stored XSS** | React output encoding everywhere; no `dangerouslySetInnerHTML`; job links restricted to `http(s)` and rendered with `rel="noopener noreferrer nofollow"`. | — |
| 7 | **CSRF** | Mutations are Server Actions (Next.js checks the Origin header); session cookie is `SameSite=Lax`, `HttpOnly`, `Secure` in production. | — |
| 8 | **Credential attacks** | scrypt password hashing with constant-time compare and dummy hash for unknown emails; sign-in and sign-up rate limits; generic error messages; in Supabase mode, Supabase Auth handles this. | In-memory limiter is per instance; use Supabase Auth or a shared store when scaling out. |
| 9 | **AI cost abuse** | Per-user hourly limit stored in the database (`ai_requests`, metadata only); timeouts and bounded retries. | — |
| 10 | **Secret leakage** | Secrets only in environment variables; only `NEXT_PUBLIC_SUPABASE_URL/ANON_KEY` reach the browser; service-role key used server-side only for account deletion; `server-only` guards on server modules. | — |
| 11 | **Clickjacking / sniffing** | `X-Frame-Options: DENY`, `nosniff`, strict referrer and permissions policies. | A full CSP is not yet configured (backlog). |
