import "server-only";
import { withUser } from "../db";
import type { Recommendation, Stage, WorkplaceType } from "../domain";
import type { FitResult, Requirement } from "../fit/types";

export type Job = {
  id: string;
  title: string;
  company: string;
  url: string;
  location: string;
  workplace_type: WorkplaceType;
  salary_min: number | null;
  salary_max: number | null;
  currency: string;
  description: string;
  source: string;
  discovered_on: string;
  closes_on: string | null;
  contact_name: string;
  contact_email: string;
  notes: string;
  created_at: string;
};

export type JobInput = Omit<Job, "id" | "created_at">;

export type JobListItem = Job & {
  fit_score: number | null;
  recommendation: Recommendation | null;
  application_id: string | null;
  stage: Stage | null;
};

const JOB_COLUMNS = `j.id, j.title, j.company, j.url, j.location, j.workplace_type, j.salary_min, j.salary_max, j.currency,
  j.description, j.source, to_char(j.discovered_on, 'YYYY-MM-DD') as discovered_on,
  to_char(j.closes_on, 'YYYY-MM-DD') as closes_on, j.contact_name, j.contact_email, j.notes, j.created_at`;

export async function listJobs(userId: string, search = ""): Promise<JobListItem[]> {
  return withUser(userId, (db) =>
    db.query<JobListItem>(
      `select ${JOB_COLUMNS}, f.score as fit_score, f.recommendation, a.id as application_id, a.stage
         from jobs j
         left join lateral (select score, recommendation from fit_analyses fa where fa.job_id = j.id order by created_at desc limit 1) f on true
         left join applications a on a.job_id = j.id
        where j.user_id = $1
          and ($2 = '' or j.title ilike '%' || $2 || '%' or j.company ilike '%' || $2 || '%')
        order by j.created_at desc`,
      [userId, search],
    ),
  );
}

export async function getJob(userId: string, jobId: string): Promise<(Job & { application_id: string | null; stage: Stage | null }) | null> {
  return withUser(userId, (db) =>
    db.one(
      `select ${JOB_COLUMNS}, a.id as application_id, a.stage from jobs j left join applications a on a.job_id = j.id
        where j.id = $1 and j.user_id = $2`,
      [jobId, userId],
    ),
  );
}

export async function createJob(userId: string, job: JobInput, requirements: Array<{ text: string; kind: "must" | "nice" }>): Promise<string> {
  return withUser(userId, async (db) => {
    const row = await db.one<{ id: string }>(
      `insert into jobs (user_id, title, company, url, location, workplace_type, salary_min, salary_max, currency, description,
                         source, discovered_on, closes_on, contact_name, contact_email, notes)
       values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16) returning id`,
      [userId, job.title, job.company, job.url, job.location, job.workplace_type, job.salary_min, job.salary_max, job.currency,
        job.description, job.source, job.discovered_on, job.closes_on, job.contact_name, job.contact_email, job.notes],
    );
    for (const [i, r] of requirements.entries()) {
      await db.query("insert into job_requirements (user_id, job_id, text, kind, position) values ($1, $2, $3, $4, $5)", [userId, row!.id, r.text, r.kind, i]);
    }
    return row!.id;
  });
}

export async function updateJob(userId: string, jobId: string, job: JobInput) {
  return withUser(userId, (db) =>
    db.one(
      `update jobs set title = $3, company = $4, url = $5, location = $6, workplace_type = $7, salary_min = $8, salary_max = $9,
              currency = $10, description = $11, source = $12, discovered_on = $13, closes_on = $14, contact_name = $15,
              contact_email = $16, notes = $17
        where id = $1 and user_id = $2 returning id`,
      [jobId, userId, job.title, job.company, job.url, job.location, job.workplace_type, job.salary_min, job.salary_max,
        job.currency, job.description, job.source, job.discovered_on, job.closes_on, job.contact_name, job.contact_email, job.notes],
    ),
  );
}

export async function deleteJob(userId: string, jobId: string) {
  await withUser(userId, (db) => db.query("delete from jobs where id = $1 and user_id = $2", [jobId, userId]));
}

export async function listRequirements(userId: string, jobId: string): Promise<Requirement[]> {
  return withUser(userId, (db) =>
    db.query<Requirement>("select id, text, kind from job_requirements where job_id = $1 and user_id = $2 order by position, created_at", [jobId, userId]),
  );
}

export async function replaceRequirements(userId: string, jobId: string, requirements: Array<{ text: string; kind: "must" | "nice" }>) {
  await withUser(userId, async (db) => {
    const job = await db.one("select 1 from jobs where id = $1 and user_id = $2", [jobId, userId]);
    if (!job) return;
    await db.query("delete from job_requirements where job_id = $1 and user_id = $2", [jobId, userId]);
    for (const [i, r] of requirements.entries()) {
      await db.query("insert into job_requirements (user_id, job_id, text, kind, position) values ($1, $2, $3, $4, $5)", [userId, jobId, r.text, r.kind, i]);
    }
  });
}

export async function addRequirement(userId: string, jobId: string, text: string, kind: "must" | "nice") {
  await withUser(userId, (db) =>
    db.query(
      `insert into job_requirements (user_id, job_id, text, kind, position)
       select $1, id, $3, $4, coalesce((select max(position) + 1 from job_requirements where job_id = $2), 0)
         from jobs where id = $2 and user_id = $1`,
      [userId, jobId, text, kind],
    ),
  );
}

export async function updateRequirementKind(userId: string, requirementId: string, kind: "must" | "nice") {
  await withUser(userId, (db) => db.query("update job_requirements set kind = $3 where id = $1 and user_id = $2", [requirementId, userId, kind]));
}

export async function deleteRequirement(userId: string, requirementId: string) {
  await withUser(userId, (db) => db.query("delete from job_requirements where id = $1 and user_id = $2", [requirementId, userId]));
}

// ---------------------------------------------------------------------------
// Fit analyses
// ---------------------------------------------------------------------------

export type StoredFit = FitResult & {
  id: string;
  resume_id: string | null;
  provider: string;
  model: string;
  prompt_version: string;
  created_at: string;
};

export async function saveFitAnalysis(
  userId: string,
  jobId: string,
  resumeId: string | null,
  result: FitResult,
  meta: { provider: string; model: string; prompt_version: string },
): Promise<string> {
  return withUser(userId, async (db) => {
    const row = await db.one<{ id: string }>(
      `insert into fit_analyses (user_id, job_id, resume_id, provider, model, prompt_version, score, recommendation, explanation,
                                 seniority_alignment, location_considerations, emphasize, questions, coverage, warnings)
       values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15) returning id`,
      [userId, jobId, resumeId, meta.provider, meta.model, meta.prompt_version, result.score, result.recommendation, result.explanation,
        JSON.stringify(result.seniority), JSON.stringify(result.location_considerations), JSON.stringify(result.emphasize),
        JSON.stringify(result.questions), JSON.stringify(result.coverage), JSON.stringify(result.warnings)],
    );
    for (const [i, m] of result.matches.entries()) {
      await db.query(
        `insert into fit_matches (user_id, analysis_id, requirement_text, requirement_kind, match_type, explanation, source_type,
                                  source_id, source_label, needs_confirmation, position)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
        [userId, row!.id, m.requirement_text, m.requirement_kind, m.match_type, m.explanation, m.source_type, m.source_id,
          m.source_label, m.needs_confirmation, i],
      );
    }
    return row!.id;
  });
}

export async function getLatestFit(userId: string, jobId: string): Promise<StoredFit | null> {
  return withUser(userId, async (db) => {
    const a = await db.one<{
      id: string; resume_id: string | null; provider: string; model: string; prompt_version: string; created_at: string; score: number;
      recommendation: Recommendation; explanation: string; seniority_alignment: FitResult["seniority"];
      location_considerations: string[]; emphasize: FitResult["emphasize"]; questions: string[];
      coverage: FitResult["coverage"]; warnings: string[];
    }>(
      `select id, resume_id, provider, model, prompt_version, created_at, score, recommendation, explanation, seniority_alignment,
              location_considerations, emphasize, questions, coverage, warnings
         from fit_analyses where job_id = $1 and user_id = $2 order by created_at desc limit 1`,
      [jobId, userId],
    );
    if (!a) return null;
    const matches = await db.query<FitResult["matches"][number]>(
      `select requirement_text, requirement_kind, match_type, explanation, source_type, source_id, source_label, needs_confirmation
         from fit_matches where analysis_id = $1 and user_id = $2 order by position`,
      [a.id, userId],
    );
    return {
      id: a.id,
      resume_id: a.resume_id,
      provider: a.provider,
      model: a.model,
      prompt_version: a.prompt_version,
      created_at: a.created_at,
      score: a.score,
      recommendation: a.recommendation,
      explanation: a.explanation,
      seniority: a.seniority_alignment,
      location_considerations: a.location_considerations,
      emphasize: a.emphasize,
      questions: a.questions,
      coverage: a.coverage,
      warnings: a.warnings,
      matches,
    };
  });
}
