# jobhunter: automated job search and application pipeline

jobhunter reads your resume, finds jobs that fit it (remote, hybrid or onsite, your choice), and fills in the application forms for you. This includes Workable forms and their custom screening questions. It keeps a record of every job so it never applies twice, and it gives you an HTML dashboard of where each job stands.

```
discover ──► search ──► score ──► apply ──► report
(web search   (job-board   (resume   (real browser:  (data/report.html)
 for company   APIs)        keywords  Workable, Greenhouse,
 boards)                    + Claude) Lever, Ashby)
```

## What it does

| Step | How |
|---|---|
| **Discover** | Runs web searches such as `site:apply.workable.com "DevOps Engineer" "Toronto"` and collects the career boards of companies hiring for your titles. Needs a search API key: `SERPAPI_KEY`, `BRAVE_API_KEY` or `GOOGLE_CSE_KEY`+`GOOGLE_CSE_ID`. |
| **Search** | Uses public job-board APIs: **Workable**, **Greenhouse**, **Lever** and **Ashby** company boards, plus the **Remotive**, **RemoteOK**, **Arbeitnow** and (with a free key) **Adzuna** aggregators. When an aggregator job links to a supported ATS, it can still be applied to automatically. |
| **Work mode** | Each job is tagged `remote` / `hybrid` / `onsite`. The ATS's own field is used when it has one (Workable, Lever and Ashby do); otherwise the location and description text decide. Filtering uses `work_modes`, `locations` (for hybrid/onsite) and `remote_regions` (for remote roles such as "Remote – US only"). |
| **Score** | Compares your titles and skills against the posting, penalises seniority mismatches, and drops jobs containing `exclude_keywords`. If Claude is configured, it re-scores the top matches, explains each fit and lists missing requirements. |
| **Apply** | Opens the application form in Chromium, uploads your resume and a cover letter written for that job, and fills in your details and the screening questions. Details on the next section. |
| **Track** | Stores everything in SQLite (`data/jobs.db`). `data/report.html` is a filterable dashboard, and each application gets a screenshot plus a record of every answer given. |

### How the forms get filled (including Workable's custom questions)

Every form field is read by its visible label, not by site-specific selectors, so this works across employers' custom questions. Each field is answered from the first source that fits:

1. **Your profile**: name, email, phone, LinkedIn/GitHub, location, current company, resume and cover-letter files.
2. **Your `answers`**: work authorization, sponsorship, salary, notice period, relocation, in-office OK, years of experience, how you heard about the job, plus your own `custom` regex → answer rules.
3. **EEO / demographic questions**: "decline to self-identify" unless you set an answer.
4. **Consent checkboxes**: required privacy/terms boxes are ticked. Optional marketing ones are left alone unless you set `optional_consents: true`.
5. **Claude**: open questions ("Why do you want to work here?", "Which university…") are answered from your resume and the job description. Claude is told never to invent facts, and anything it isn't sure about is flagged.

Two modes (`apply.mode`):

- **`review`** (the default): jobhunter fills in the whole form. A banner then tells you what to check, **you click Submit**, and it records the application. With `headless: true` this is a dry run that saves screenshots only.
- **`submit`**: fully automatic, but only when every required field was answered confidently. Anything uncertain (an unknown required question, a low-confidence answer, or a CAPTCHA) falls back to review.

**CAPTCHAs are never bypassed.** When a form shows one, a visible browser waits for you to solve it; in headless/CI runs the job is marked `needs_review`. Workable applications normally don't need a candidate account. If a site does ask you to sign in or verify your email, do it once in the visible browser: the browser profile in `data/browser-profile` keeps you logged in for later runs.

## Setup

```bash
pip install -r requirements.txt
python -m playwright install chromium

python -m jobhunter init            # creates config/profile.yaml (git-ignored)
cp ~/Documents/MyResume.pdf resume.pdf
$EDITOR config/profile.yaml         # details, titles, work modes, locations, answers
$EDITOR config/companies.yaml       # optional: company boards to always watch
export ANTHROPIC_API_KEY=...        # optional but recommended (scoring, questions, cover letters)
```

## Use

```bash
python -m jobhunter run --no-apply      # discover (if enabled) + search + score + report
python -m jobhunter list                # top matches:  score  status  mode  title  company  uid
python -m jobhunter apply --limit 5     # fill the top 5 in a visible browser; you review and submit
python -m jobhunter apply --submit      # fully automatic where confident (daily_limit applies)
python -m jobhunter apply --job workable:acme:ab12cd34   # one specific job
python -m jobhunter list --status needs_review
python -m jobhunter mark <uid> applied  # after finishing one by hand
python -m jobhunter report              # data/report.html
```

Job statuses: `matched` → `applied` | `needs_review` | `manual` (the ATS isn't automated, so apply by hand at the link) | `failed`; `skipped` means it didn't fit.

## Running on a schedule

- **Azure DevOps**: `azure-pipelines.yml` runs lint and tests on every push, and every weekday runs search → score → apply (headless) → report. The tracker is published as a pipeline artifact and restored on the next run. Upload `profile.yaml` and `resume.pdf` as *Secure files*, and put `ANTHROPIC_API_KEY` in a variable group called `jobhunter`. Queue a run manually with **autoApply** ticked to submit automatically.
- **GitHub Actions**: `.github/workflows/jobhunter.yml` does the same. Set the repository variable `JOBHUNTER_ENABLED=true` and the secrets listed at the top of the file. **Keep the repo private** if you enable it: the uploaded report and screenshots contain your personal details.

Scheduled runs are headless, so applications that need a human collect in `needs_review`. Finish them locally with `python -m jobhunter apply --job <uid>`.

## Ground rules this tool follows

- It uses public, documented job-board endpoints. It does **not** scrape LinkedIn or Indeed, whose terms prohibit automated access and whose accounts get banned for it.
- There's a daily application cap (`daily_limit`, default 15) and every job is applied to at most once.
- Answers come from your data. Legal and eligibility questions (work authorization, sponsorship) are only ever answered from your `answers` block, and the prompt forbids Claude from inventing experience, credentials or status.
- You are responsible for what gets submitted in your name. Start with `review` mode, check the screenshots in `data/applications/`, and switch to `submit` once you trust your answers.

## Development

```bash
pip install -r requirements-dev.txt
ruff check jobhunter tests && python -m pytest -q
```

The browser tests fill and submit a local Workable-style form (`tests/fixtures/workable_form.html`). If Playwright's own Chromium isn't installed, set `JOBHUNTER_BROWSER=/path/to/chrome` (or `apply.browser_executable`).

```
jobhunter/
  sources/     greenhouse, lever, ashby, workable, aggregators, adzuna, discovery, detect (URL → ATS)
  apply/       extract.js (reads any form), fields.py (what to answer), browser.py (fill/submit/hand-over)
  resume.py    text + skills + years from PDF/DOCX/TXT
  matcher.py   keyword scoring      workmode.py  remote/hybrid/onsite + location filter
  llm.py       Claude: fit score, form answers, cover letters
  store.py     SQLite tracker        pipeline.py / cli.py / report.py
```
