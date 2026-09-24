import "./load-env";
import { readFileSync } from "node:fs";
import path from "node:path";
import { Client } from "pg";
import { DEFAULT_CHECKLIST } from "../src/lib/applications/checklist";
import { addDays, isoDateInZone } from "../src/lib/dates";
import { hashPassword } from "../src/lib/auth/password";
import { buildSources, yearsOfExperience, type CareerProfile } from "../src/lib/fit/corpus";
import { finalizeFit } from "../src/lib/fit/finalize";
import { heuristicFit } from "../src/lib/fit/heuristic";
import { extractRequirements } from "../src/lib/fit/requirements";
import type { FitInput } from "../src/lib/fit/types";
import { parseResumeText } from "../src/lib/resume/parse";

/**
 * Seeds a demo account with realistic data (local mode only).
 *   email:    demo@jobpilot.local
 *   password: demo-password-123
 * Re-running the script resets the demo account. Other accounts are untouched.
 */

const DEMO_EMAIL = "demo@jobpilot.local";
const DEMO_PASSWORD = "demo-password-123";

const JOBS = [
  {
    title: "Senior Platform Engineer",
    company: "Brightline Health",
    location: "London",
    workplace_type: "hybrid",
    salary_min: 90000,
    salary_max: 110000,
    currency: "GBP",
    source: "LinkedIn",
    stage: "interview",
    daysAgo: 24,
    description: `Brightline Health is building digital care services used by 2 million patients.

Requirements:
- 5+ years of experience in platform or infrastructure engineering
- Strong experience with Kubernetes and Terraform
- Experience running production services on AWS
- CI/CD pipeline design with GitHub Actions or similar
- Experience mentoring engineers

Nice to have:
- Observability with Prometheus and Grafana
- Experience in a regulated industry (healthcare or finance)`,
  },
  {
    title: "Site Reliability Engineer",
    company: "Orbital Logistics",
    location: "Remote (UK)",
    workplace_type: "remote",
    salary_min: 80000,
    salary_max: 95000,
    currency: "GBP",
    source: "Company website",
    stage: "applied",
    daysAgo: 10,
    description: `We run the routing platform for 400 delivery fleets.

What you'll bring:
- Experience owning on-call and incident response for production systems
- Proficiency with Go or Python
- Experience with Google Cloud Platform
- Solid PostgreSQL operational knowledge

Preferred:
- Experience with Datadog
- Chaos engineering practice`,
  },
  {
    title: "Staff DevOps Engineer",
    company: "Fernway Bank",
    location: "Edinburgh",
    workplace_type: "onsite",
    salary_min: 105000,
    salary_max: 125000,
    currency: "GBP",
    source: "Recruiter",
    stage: "rejected",
    daysAgo: 35,
    description: `Requirements:
- 10+ years of experience in DevOps
- Deep expertise with Azure and Azure DevOps
- Experience with mainframe integration
- Security clearance or eligibility for SC clearance

Nice to have:
- Ansible automation`,
  },
  {
    title: "Platform Engineer",
    company: "Kestrel Games",
    location: "Manchester",
    workplace_type: "hybrid",
    salary_min: 70000,
    salary_max: 85000,
    currency: "GBP",
    source: "Referral",
    stage: null,
    daysAgo: 2,
    description: `Requirements:
- Experience with Kubernetes in production
- Terraform and infrastructure as code
- Experience building developer tooling
- Scripting in Python or Bash

Nice to have:
- Experience with game backend services`,
  },
] as const;

async function main() {
  if ((process.env.AUTH_MODE ?? "local") !== "local") {
    throw new Error("The demo seed only runs with AUTH_MODE=local. For Supabase, sign up in the app instead.");
  }
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  const today = isoDateInZone(new Date(), "UTC");
  const at = (daysAgo: number, hour = 10) => new Date(Date.parse(`${addDays(today, -daysAgo)}T${String(hour).padStart(2, "0")}:00:00Z`)).toISOString();

  try {
    await client.query("begin");
    await client.query("delete from auth.users where email = $1", [DEMO_EMAIL]);
    const { rows: [user] } = await client.query<{ id: string }>(
      "insert into auth.users (email, encrypted_password) values ($1, $2) returning id",
      [DEMO_EMAIL, await hashPassword(DEMO_PASSWORD)],
    );
    const uid = user!.id;
    const q = async <T extends Record<string, unknown>>(sql: string, params: unknown[]) => (await client.query<T>(sql, params)).rows;

    await q(
      `insert into profiles (user_id, full_name, current_title, preferred_locations, workplace_preference, target_salary, salary_currency,
                             employment_types, willing_to_relocate, work_authorization_notes, search_started_on, onboarding_completed_at)
       values ($1, 'Alex Morgan', 'Senior Platform Engineer', $2, 'hybrid', 95000, 'GBP', '{full_time}', false, 'UK citizen. No sponsorship needed in the UK.', $3, now())`,
      [uid, ["London", "Manchester", "Remote"], addDays(today, -40)],
    );
    await q("insert into user_settings (user_id, weekly_application_goal, follow_up_after_days) values ($1, 4, 7)", [uid]);
    for (const [i, title] of ["Platform Engineer", "Site Reliability Engineer", "DevOps Engineer"].entries()) {
      await q("insert into target_roles (user_id, title, position) values ($1, $2, $3)", [uid, title, i]);
    }

    // Resume, parsed exactly as the app would parse a pasted resume.
    const text = readFileSync(path.join(__dirname, "..", "tests", "fixtures", "sample-resume.txt"), "utf8");
    const { draft, status, warnings } = parseResumeText(text, "Platform engineering resume");
    const [resume] = await q<{ id: string }>(
      `insert into resumes (user_id, title, source_type, raw_text, parse_status, parse_warnings, contact, summary, languages, is_primary)
       values ($1, $2, 'paste', $3, $4, $5, $6, $7, $8, true) returning id`,
      [uid, draft.title, text, status, JSON.stringify(warnings), JSON.stringify(draft.contact), draft.summary, draft.languages],
    );
    const resumeId = resume!.id;
    const employment: CareerProfile["employment"] = [];
    for (const [i, e] of draft.employment.entries()) {
      const [row] = await q<{ id: string }>(
        `insert into employment_entries (user_id, resume_id, employer, title, location, start_date, end_date, is_current, responsibilities, achievements, position)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) returning id`,
        [uid, resumeId, e.employer, e.title, e.location, e.start_date, e.end_date, e.is_current, e.responsibilities, e.achievements, i],
      );
      employment.push({ ...e, id: row!.id });
    }
    const skills = [];
    for (const [i, s] of draft.skills.entries()) {
      const [row] = await q<{ id: string }>("insert into skills (user_id, resume_id, name, category, position) values ($1, $2, $3, $4, $5) returning id", [uid, resumeId, s.name, s.category, i]);
      skills.push({ ...s, id: row!.id });
    }
    const certifications = [];
    for (const [i, c] of draft.certifications.entries()) {
      const [row] = await q<{ id: string }>("insert into certifications (user_id, resume_id, name, issuer, issued_on, position) values ($1, $2, $3, $4, $5, $6) returning id", [uid, resumeId, c.name, c.issuer, c.issued_on, i]);
      certifications.push({ ...c, id: row!.id });
    }
    const education = [];
    for (const [i, ed] of draft.education.entries()) {
      const [row] = await q<{ id: string }>(
        "insert into education_entries (user_id, resume_id, institution, qualification, field_of_study, end_date, position) values ($1, $2, $3, $4, $5, $6, $7) returning id",
        [uid, resumeId, ed.institution, ed.qualification, ed.field_of_study, ed.end_date, i],
      );
      education.push({ ...ed, id: row!.id });
    }
    const projects = [];
    for (const [i, p] of draft.projects.entries()) {
      const [row] = await q<{ id: string }>("insert into projects (user_id, resume_id, name, description, skills, position) values ($1, $2, $3, $4, $5, $6) returning id", [uid, resumeId, p.name, p.description, p.skills, i]);
      projects.push({ ...p, id: row!.id });
    }

    // Evidence vault: two verified STAR items and one awaiting review.
    const evidenceSeed = [
      {
        title: "Kubernetes migration for payments services",
        organization: "Northwind Payments",
        situation: "Forty payment services ran on hand-managed EC2 instances with slow, risky deployments.",
        action: "Led migration of 40 services from EC2 to Kubernetes (EKS), cutting infrastructure cost by 28%",
        result: "All 40 services moved without a customer-facing incident; infrastructure cost fell by 28%.",
        skills: ["Kubernetes", "AWS", "Terraform"],
        metric: "28% lower infrastructure cost",
        status: "verified",
        employment: employment[0]?.id,
      },
      {
        title: "Faster, safer releases at Contoso Retail",
        organization: "Contoso Retail",
        situation: "Releases were manual and took two hours, so the team shipped rarely.",
        action: "Automated release process with Jenkins and Ansible, reducing deployment time from 2 hours to 15 minutes",
        result: "Deployment time dropped from 2 hours to 15 minutes.",
        skills: ["Jenkins", "Ansible", "CI/CD"],
        metric: "2 hours to 15 minutes",
        status: "verified",
        employment: employment[1]?.id,
      },
      {
        title: "Terraform module library",
        organization: "Northwind Payments",
        situation: "",
        action: "Built a Terraform module library adopted by 12 product teams",
        result: "",
        skills: ["Terraform"],
        metric: "12 product teams",
        status: "unverified",
        employment: employment[0]?.id,
      },
    ];
    const evidence: CareerProfile["evidence"] = [];
    for (const ev of evidenceSeed) {
      const [row] = await q<{ id: string }>(
        `insert into evidence_items (user_id, title, organization, situation, action, result, skills, metric, source, source_employment_id, confidence, verification_status, notes)
         values ($1, $2, $3, $4, $5, $6, $7, $8, 'resume', $9, 'high', $10, '') returning id`,
        [uid, ev.title, ev.organization, ev.situation, ev.action, ev.result, ev.skills, ev.metric, ev.employment ?? null, ev.status],
      );
      evidence.push({ id: row!.id, title: ev.title, organization: ev.organization, situation: ev.situation, action: ev.action, result: ev.result, skills: ev.skills, metric: ev.metric, verification_status: ev.status });
    }

    const career: CareerProfile = { resume: { id: resumeId, summary: draft.summary }, employment, education, certifications, skills, projects, evidence };
    const sources = buildSources(career);

    const [version] = await q<{ id: string }>(
      `insert into resume_versions (user_id, resume_id, name, summary, content) values ($1, $2, 'Platform roles — general', $3, $4) returning id`,
      [uid, resumeId, draft.summary, JSON.stringify({
        employment: employment.map((e) => ({
          employment_id: e.id,
          heading: [e.title, e.employer].join(" · "),
          dates: [e.start_date, e.is_current ? "Present" : e.end_date].filter(Boolean).join(" – "),
          bullets: [...e.achievements, ...e.responsibilities],
        })),
        skills: skills.map((s) => s.name),
      })],
    );

    for (const job of JOBS) {
      const [jobRow] = await q<{ id: string }>(
        `insert into jobs (user_id, title, company, location, workplace_type, salary_min, salary_max, currency, description, source, discovered_on, closes_on, created_at)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) returning id`,
        [uid, job.title, job.company, job.location, job.workplace_type, job.salary_min, job.salary_max, job.currency, job.description, job.source,
          addDays(today, -job.daysAgo), job.stage === null ? addDays(today, 5) : null, at(job.daysAgo)],
      );
      const jobId = jobRow!.id;
      const requirements = [];
      for (const [i, r] of extractRequirements(job.description).entries()) {
        const [row] = await q<{ id: string }>("insert into job_requirements (user_id, job_id, text, kind, position) values ($1, $2, $3, $4, $5) returning id", [uid, jobId, r.text, r.kind, i]);
        requirements.push({ id: row!.id, ...r });
      }
      const input: FitInput = {
        job: { title: job.title, company: job.company, location: job.location, workplace_type: job.workplace_type, salary_max: job.salary_max, currency: job.currency, description: job.description, requirements },
        profile: {
          current_title: "Senior Platform Engineer", target_titles: ["Platform Engineer"], preferred_locations: ["London", "Manchester", "Remote"],
          workplace_preference: "hybrid", willing_to_relocate: false, work_authorization_notes: "UK citizen. No sponsorship needed in the UK.",
          target_salary: 95000, salary_currency: "GBP", years_experience: yearsOfExperience(employment),
        },
        sources,
      };
      const fit = finalizeFit(heuristicFit(input), input);
      const [analysis] = await q<{ id: string }>(
        `insert into fit_analyses (user_id, job_id, resume_id, provider, model, prompt_version, score, recommendation, explanation, seniority_alignment,
                                   location_considerations, emphasize, questions, coverage, warnings, created_at)
         values ($1, $2, $3, 'mock', 'deterministic-templates', 'fit.v1', $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) returning id`,
        [uid, jobId, resumeId, fit.score, fit.recommendation, fit.explanation, JSON.stringify(fit.seniority), JSON.stringify(fit.location_considerations),
          JSON.stringify(fit.emphasize), JSON.stringify(fit.questions), JSON.stringify(fit.coverage), JSON.stringify(fit.warnings), at(job.daysAgo, 11)],
      );
      for (const [i, m] of fit.matches.entries()) {
        await q(
          `insert into fit_matches (user_id, analysis_id, requirement_text, requirement_kind, match_type, explanation, source_type, source_id, source_label, needs_confirmation, position)
           values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
          [uid, analysis!.id, m.requirement_text, m.requirement_kind, m.match_type, m.explanation, m.source_type, m.source_id, m.source_label, m.needs_confirmation, i],
        );
      }

      if (job.stage === null) continue;
      // Record a realistic event history ending in the target stage.
      const path: Record<string, Array<[string, number]>> = {
        interview: [["interested", 24], ["preparing", 23], ["applied", 21], ["recruiter_screen", 14], ["interview", 6]],
        applied: [["interested", 10], ["applied", 9]],
        rejected: [["interested", 35], ["applied", 33], ["rejected", 20]],
      };
      const steps = path[job.stage]!;
      const appliedDaysAgo = steps.find(([s]) => s === "applied")?.[1];
      const [app] = await q<{ id: string }>(
        `insert into applications (user_id, job_id, resume_version_id, stage, stage_changed_at, applied_on, follow_up_on, rejection_reason, checklist, selected_evidence_ids, created_at)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $11, $9, $10) returning id`,
        [uid, jobId, version!.id, job.stage, at(steps.at(-1)![1]), appliedDaysAgo !== undefined ? addDays(today, -appliedDaysAgo) : null,
          job.stage === "applied" ? addDays(today, -2) : null, job.stage === "rejected" ? "Required deep Azure experience" : "",
          evidence.filter((e) => e.verification_status === "verified").map((e) => e.id), at(job.daysAgo),
          JSON.stringify(DEFAULT_CHECKLIST.map((c, i) => ({ ...c, done: i < 4 })))],
      );
      let from: string | null = null;
      for (const [stage, daysAgo] of steps) {
        await q("insert into application_events (user_id, application_id, from_stage, to_stage, occurred_at) values ($1, $2, $3, $4, $5)", [uid, app!.id, from, stage, at(daysAgo)]);
        from = stage;
      }
      if (job.stage === "applied") {
        await q("insert into tasks (user_id, application_id, kind, title, due_on) values ($1, $2, 'follow_up', $3, $4)", [uid, app!.id, `Follow up on your ${job.company} application`, addDays(today, -2)]);
      }
      if (job.stage === "interview") {
        const [interview] = await q<{ id: string }>(
          "insert into interviews (user_id, application_id, scheduled_at, kind, interviewers, location) values ($1, $2, $3, 'technical', 'Priya Shah, Engineering Manager', 'Video call') returning id",
          [uid, app!.id, `${addDays(today, 2)}T14:00:00Z`],
        );
        await q("insert into tasks (user_id, application_id, interview_id, kind, title, due_on) values ($1, $2, $3, 'interview_prep', $4, $5)", [uid, app!.id, interview!.id, `Prepare for your ${job.company} interview`, addDays(today, 1)]);
        await q("insert into contacts (user_id, application_id, name, role, email) values ($1, $2, 'Sam Carter', 'recruiter', 'sam.carter@example.com')", [uid, app!.id]);
      }
    }

    await client.query("commit");
    console.log(`Seeded demo account: ${DEMO_EMAIL} / ${DEMO_PASSWORD}`);
  } catch (error) {
    await client.query("rollback");
    throw error;
  } finally {
    await client.end();
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
