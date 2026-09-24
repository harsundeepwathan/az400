import "server-only";
import { withUser, type Db } from "../db";
import type { CareerProfile } from "../fit/corpus";
import type { ParseStatus, ResumeDraft } from "../resume/schema";

export type ResumeSummary = {
  id: string;
  title: string;
  source_type: "upload" | "paste";
  original_filename: string | null;
  parse_status: ParseStatus;
  is_primary: boolean;
  created_at: string;
  updated_at: string;
  employment_count: number;
  skill_count: number;
};

export type ResumeDetail = Omit<ResumeDraft, "employment"> & {
  id: string;
  is_primary: boolean;
  source_type: string;
  original_filename: string | null;
  storage_path: string | null;
  parse_status: ParseStatus;
  parse_warnings: string[];
  raw_text: string;
  employment: Array<ResumeDraft["employment"][number] & { id: string }>;
};

export async function listResumes(userId: string): Promise<ResumeSummary[]> {
  return withUser(userId, (db) =>
    db.query<ResumeSummary>(
      `select r.id, r.title, r.source_type, r.original_filename, r.parse_status, r.is_primary, r.created_at, r.updated_at,
              (select count(*)::int from employment_entries e where e.resume_id = r.id) as employment_count,
              (select count(*)::int from skills s where s.resume_id = r.id) as skill_count
         from resumes r where r.user_id = $1 order by r.is_primary desc, r.created_at desc`,
      [userId],
    ),
  );
}

async function loadDetail(db: Db, userId: string, resumeId: string): Promise<ResumeDetail | null> {
  const r = await db.one<{
    id: string; title: string; contact: Partial<ResumeDraft["contact"]>; summary: string; languages: string[]; is_primary: boolean;
    source_type: string; original_filename: string | null; storage_path: string | null; parse_status: ParseStatus;
    parse_warnings: string[]; raw_text: string;
  }>(
    `select id, title, contact, summary, languages, is_primary, source_type, original_filename, storage_path,
            parse_status, parse_warnings, raw_text
       from resumes where id = $1 and user_id = $2`,
    [resumeId, userId],
  );
  if (!r) return null;
  const args = [resumeId, userId];
  const [employment, education, certifications, skills, projects] = await Promise.all([
    db.query<ResumeDetail["employment"][number]>(
      `select id, employer, title, location, start_date, end_date, is_current, responsibilities, achievements
         from employment_entries where resume_id = $1 and user_id = $2 order by position`, args),
    db.query<ResumeDraft["education"][number]>(
      `select id, institution, qualification, field_of_study, start_date, end_date, notes
         from education_entries where resume_id = $1 and user_id = $2 order by position`, args),
    db.query<ResumeDraft["certifications"][number]>(
      `select id, name, issuer, issued_on, expires_on from certifications where resume_id = $1 and user_id = $2 order by position`, args),
    db.query<ResumeDraft["skills"][number]>(
      `select id, name, category from skills where resume_id = $1 and user_id = $2 order by position`, args),
    db.query<ResumeDraft["projects"][number]>(
      `select id, name, description, skills, url from projects where resume_id = $1 and user_id = $2 order by position`, args),
  ]);
  return {
    ...r,
    contact: { name: "", email: "", phone: "", location: "", links: [], ...r.contact },
    employment,
    education,
    certifications,
    skills,
    projects,
  };
}

export async function getResume(userId: string, resumeId: string): Promise<ResumeDetail | null> {
  return withUser(userId, (db) => loadDetail(db, userId, resumeId));
}

type ChildSpec = { table: string; columns: string[] };

/**
 * Updates rows that still exist (preserving their ids, which fit analyses and
 * evidence items cite), inserts new rows and deletes rows the user removed.
 */
async function syncChildren(db: Db, spec: ChildSpec, userId: string, resumeId: string, rows: Array<Record<string, unknown> & { id?: string }>) {
  const kept: string[] = [];
  for (const [position, row] of rows.entries()) {
    const values = spec.columns.map((c) => row[c]);
    if (row.id) {
      const setClause = spec.columns.map((c, i) => `${c} = $${i + 4}`).join(", ");
      const updated = await db.one<{ id: string }>(
        `update ${spec.table} set ${setClause}, position = $${spec.columns.length + 4}
          where id = $1 and user_id = $2 and resume_id = $3 returning id`,
        [row.id, userId, resumeId, ...values, position],
      );
      if (updated) {
        kept.push(updated.id);
        continue;
      }
    }
    const cols = ["user_id", "resume_id", ...spec.columns, "position"];
    const placeholders = cols.map((_, i) => `$${i + 1}`).join(", ");
    const inserted = await db.one<{ id: string }>(
      `insert into ${spec.table} (${cols.join(", ")}) values (${placeholders}) returning id`,
      [userId, resumeId, ...values, position],
    );
    kept.push(inserted!.id);
  }
  await db.query(`delete from ${spec.table} where resume_id = $1 and user_id = $2 and not (id = any($3::uuid[]))`, [resumeId, userId, kept]);
}

const SPECS = {
  employment: { table: "employment_entries", columns: ["employer", "title", "location", "start_date", "end_date", "is_current", "responsibilities", "achievements"] },
  education: { table: "education_entries", columns: ["institution", "qualification", "field_of_study", "start_date", "end_date", "notes"] },
  certifications: { table: "certifications", columns: ["name", "issuer", "issued_on", "expires_on"] },
  skills: { table: "skills", columns: ["name", "category"] },
  projects: { table: "projects", columns: ["name", "description", "skills", "url"] },
} satisfies Record<string, ChildSpec>;

export type NewResumeMeta = {
  source_type: "upload" | "paste";
  original_filename: string | null;
  storage_path: string | null;
  mime_type: string | null;
  file_size: number | null;
  raw_text: string;
  parse_status: ParseStatus;
  parse_warnings: string[];
};

function dedupeSkills(skills: ResumeDraft["skills"]) {
  const seen = new Set<string>();
  return skills.filter((s) => (seen.has(s.name.toLowerCase()) ? false : (seen.add(s.name.toLowerCase()), true)));
}

async function writeChildren(db: Db, userId: string, resumeId: string, draft: ResumeDraft) {
  await syncChildren(db, SPECS.employment, userId, resumeId, draft.employment);
  await syncChildren(db, SPECS.education, userId, resumeId, draft.education);
  await syncChildren(db, SPECS.certifications, userId, resumeId, draft.certifications);
  await syncChildren(db, SPECS.skills, userId, resumeId, dedupeSkills(draft.skills));
  await syncChildren(db, SPECS.projects, userId, resumeId, draft.projects);
}

export async function createResume(userId: string, draft: ResumeDraft, meta: NewResumeMeta): Promise<string> {
  return withUser(userId, async (db) => {
    const hasPrimary = await db.one("select 1 from resumes where user_id = $1 and is_primary", [userId]);
    const row = await db.one<{ id: string }>(
      `insert into resumes (user_id, title, source_type, original_filename, storage_path, mime_type, file_size, raw_text,
                            parse_status, parse_warnings, contact, summary, languages, is_primary)
       values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14) returning id`,
      [
        userId, draft.title, meta.source_type, meta.original_filename, meta.storage_path, meta.mime_type, meta.file_size,
        meta.raw_text, meta.parse_status, JSON.stringify(meta.parse_warnings), JSON.stringify(draft.contact), draft.summary,
        draft.languages, !hasPrimary,
      ],
    );
    await writeChildren(db, userId, row!.id, draft);
    return row!.id;
  });
}

export async function updateResume(userId: string, resumeId: string, draft: ResumeDraft): Promise<boolean> {
  return withUser(userId, async (db) => {
    const row = await db.one(
      "update resumes set title = $3, contact = $4, summary = $5, languages = $6 where id = $1 and user_id = $2 returning id",
      [resumeId, userId, draft.title, JSON.stringify(draft.contact), draft.summary, draft.languages],
    );
    if (!row) return false;
    await writeChildren(db, userId, resumeId, draft);
    return true;
  });
}

export async function setPrimaryResume(userId: string, resumeId: string) {
  await withUser(userId, async (db) => {
    const exists = await db.one("select 1 from resumes where id = $1 and user_id = $2", [resumeId, userId]);
    if (!exists) return;
    await db.query("update resumes set is_primary = false where user_id = $1 and is_primary", [userId]);
    await db.query("update resumes set is_primary = true where id = $1 and user_id = $2", [resumeId, userId]);
  });
}

/** Deletes a resume and returns its storage path so the caller can remove the file. */
export async function deleteResume(userId: string, resumeId: string): Promise<{ storage_path: string | null } | null> {
  return withUser(userId, async (db) => {
    const row = await db.one<{ storage_path: string | null; is_primary: boolean }>(
      "delete from resumes where id = $1 and user_id = $2 returning storage_path, is_primary",
      [resumeId, userId],
    );
    if (row?.is_primary) {
      await db.query(
        "update resumes set is_primary = true where id = (select id from resumes where user_id = $1 order by created_at desc limit 1)",
        [userId],
      );
    }
    return row ? { storage_path: row.storage_path } : null;
  });
}

/** The career profile used for fit analysis: the primary resume plus the evidence vault. */
export async function getCareerProfile(userId: string): Promise<CareerProfile & { resumeTitle: string | null }> {
  return withUser(userId, async (db) => {
    const primary = await db.one<{ id: string }>("select id from resumes where user_id = $1 and is_primary", [userId]);
    const detail = primary ? await loadDetail(db, userId, primary.id) : null;
    const evidence = await db.query<CareerProfile["evidence"][number]>(
      `select id, title, organization, situation, action, result, skills, metric, verification_status
         from evidence_items where user_id = $1 order by updated_at desc`,
      [userId],
    );
    return {
      resumeTitle: detail?.title ?? null,
      resume: detail ? { id: detail.id, summary: detail.summary } : null,
      employment: detail?.employment ?? [],
      education: (detail?.education ?? []).map((e) => ({ ...e, id: e.id! })),
      certifications: (detail?.certifications ?? []).map((c) => ({ ...c, id: c.id! })),
      skills: (detail?.skills ?? []).map((s) => ({ ...s, id: s.id! })),
      projects: (detail?.projects ?? []).map((p) => ({ ...p, id: p.id! })),
      evidence,
    };
  });
}

// ---------------------------------------------------------------------------
// Resume versions
// ---------------------------------------------------------------------------

export type VersionContent = {
  employment: Array<{ employment_id: string; heading: string; dates: string; bullets: string[] }>;
  skills: string[];
};

export type ResumeVersion = {
  id: string;
  resume_id: string;
  job_id: string | null;
  job_label: string | null;
  name: string;
  summary: string;
  content: VersionContent;
  notes: string;
  created_at: string;
  updated_at: string;
  application_count: number;
};

export async function listVersions(userId: string): Promise<ResumeVersion[]> {
  return withUser(userId, (db) =>
    db.query<ResumeVersion>(
      `select v.id, v.resume_id, v.job_id, case when j.id is null then null else j.title || ' — ' || j.company end as job_label,
              v.name, v.summary, v.content, v.notes, v.created_at, v.updated_at,
              (select count(*)::int from applications a where a.resume_version_id = v.id) as application_count
         from resume_versions v left join jobs j on j.id = v.job_id
        where v.user_id = $1 order by v.created_at desc`,
      [userId],
    ),
  );
}

export async function getVersion(userId: string, versionId: string): Promise<ResumeVersion | null> {
  return withUser(userId, (db) =>
    db.one<ResumeVersion>(
      `select v.id, v.resume_id, v.job_id, case when j.id is null then null else j.title || ' — ' || j.company end as job_label,
              v.name, v.summary, v.content, v.notes, v.created_at, v.updated_at, 0 as application_count
         from resume_versions v left join jobs j on j.id = v.job_id
        where v.id = $1 and v.user_id = $2`,
      [versionId, userId],
    ),
  );
}

function formatRange(start: string, end: string, current: boolean) {
  return [start, current ? "Present" : end].filter(Boolean).join(" – ");
}

/** Creates a version as an exact copy of the resume; the user edits it from there. */
export async function createVersion(userId: string, resumeId: string, name: string, jobId: string | null): Promise<string | null> {
  return withUser(userId, async (db) => {
    const detail = await loadDetail(db, userId, resumeId);
    if (!detail) return null;
    const content: VersionContent = {
      employment: detail.employment.map((e) => ({
        employment_id: e.id,
        heading: [e.title, e.employer, e.location].filter(Boolean).join(" · "),
        dates: formatRange(e.start_date, e.end_date, e.is_current),
        bullets: [...e.achievements, ...e.responsibilities],
      })),
      skills: detail.skills.map((s) => s.name),
    };
    const row = await db.one<{ id: string }>(
      `insert into resume_versions (user_id, resume_id, job_id, name, summary, content)
       values ($1, $2, $3, $4, $5, $6) returning id`,
      [userId, resumeId, jobId, name, detail.summary, JSON.stringify(content)],
    );
    return row!.id;
  });
}

export async function updateVersion(userId: string, versionId: string, v: { name: string; summary: string; notes: string; content: VersionContent }) {
  return withUser(userId, (db) =>
    db.one(
      "update resume_versions set name = $3, summary = $4, notes = $5, content = $6 where id = $1 and user_id = $2 returning id",
      [versionId, userId, v.name, v.summary, v.notes, JSON.stringify(v.content)],
    ),
  );
}

export async function deleteVersion(userId: string, versionId: string) {
  await withUser(userId, (db) => db.query("delete from resume_versions where id = $1 and user_id = $2", [versionId, userId]));
}

export async function getResumeForPrint(userId: string, resumeId: string) {
  return withUser(userId, (db) => loadDetail(db, userId, resumeId));
}
