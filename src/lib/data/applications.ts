import "server-only";
import { withUser, type Db } from "../db";
import type { Stage } from "../domain";
import { applicationDeadlineDueDate, interviewPrepDueDate, planTransition, type PlannedTask } from "../applications/stages";
import type { ISODate } from "../dates";
import { DEFAULT_CHECKLIST, type ChecklistItem } from "../applications/checklist";

export type { ChecklistItem };


export type ApplicationCard = {
  id: string;
  job_id: string;
  job_title: string;
  company: string;
  location: string;
  stage: Stage;
  stage_changed_at: string;
  applied_on: string | null;
  next_action: string;
  next_action_on: string | null;
  follow_up_on: string | null;
  fit_score: number | null;
  source: string;
  updated_at: string;
};

export type Application = ApplicationCard & {
  resume_version_id: string | null;
  resume_version_name: string | null;
  salary_expectation: string;
  rejection_reason: string;
  offer_details: string;
  offer_deadline: string | null;
  notes: string;
  checklist: ChecklistItem[];
  selected_evidence_ids: string[];
  job_closes_on: string | null;
};


const CARD_COLUMNS = `a.id, a.job_id, j.title as job_title, j.company, j.location, a.stage, a.stage_changed_at,
  to_char(a.applied_on, 'YYYY-MM-DD') as applied_on, a.next_action, to_char(a.next_action_on, 'YYYY-MM-DD') as next_action_on,
  to_char(a.follow_up_on, 'YYYY-MM-DD') as follow_up_on, j.source, a.updated_at,
  (select score from fit_analyses f where f.job_id = j.id order by f.created_at desc limit 1) as fit_score`;

export async function listApplications(userId: string, filters: { q?: string; stage?: Stage | "" } = {}): Promise<ApplicationCard[]> {
  return withUser(userId, (db) =>
    db.query<ApplicationCard>(
      `select ${CARD_COLUMNS} from applications a join jobs j on j.id = a.job_id
        where a.user_id = $1
          and ($2 = '' or j.title ilike '%' || $2 || '%' or j.company ilike '%' || $2 || '%' or a.notes ilike '%' || $2 || '%')
          and ($3 = '' or a.stage = $3)
        order by a.stage_changed_at desc`,
      [userId, filters.q ?? "", filters.stage ?? ""],
    ),
  );
}

export async function getApplication(userId: string, id: string): Promise<Application | null> {
  return withUser(userId, (db) =>
    db.one<Application>(
      `select ${CARD_COLUMNS}, a.resume_version_id, v.name as resume_version_name, a.salary_expectation, a.rejection_reason,
              a.offer_details, to_char(a.offer_deadline, 'YYYY-MM-DD') as offer_deadline, a.notes, a.checklist,
              a.selected_evidence_ids, to_char(j.closes_on, 'YYYY-MM-DD') as job_closes_on
         from applications a join jobs j on j.id = a.job_id left join resume_versions v on v.id = a.resume_version_id
        where a.id = $1 and a.user_id = $2`,
      [id, userId],
    ),
  );
}

async function insertTasks(db: Db, userId: string, applicationId: string, tasks: PlannedTask[], interviewId: string | null = null) {
  for (const t of tasks) {
    // One open automatic reminder of each kind per application (or interview).
    await db.query(
      `update tasks set completed_at = now()
        where user_id = $1 and application_id = $2 and kind = $3 and completed_at is null
          and ($4::uuid is null or interview_id = $4)`,
      [userId, applicationId, t.kind, interviewId],
    );
    await db.query(
      "insert into tasks (user_id, application_id, interview_id, kind, title, due_on) values ($1, $2, $3, $4, $5, $6)",
      [userId, applicationId, interviewId, t.kind, t.title, t.due_on],
    );
  }
}

/** Creates the application for a job (idempotent) and records the initial event. */
export async function createApplication(userId: string, jobId: string, today: ISODate, stage: Stage = "interested"): Promise<string | null> {
  return withUser(userId, async (db) => {
    const job = await db.one<{ company: string; closes_on: string | null }>(
      "select company, to_char(closes_on, 'YYYY-MM-DD') as closes_on from jobs where id = $1 and user_id = $2",
      [jobId, userId],
    );
    if (!job) return null;
    const existing = await db.one<{ id: string }>("select id from applications where job_id = $1 and user_id = $2", [jobId, userId]);
    if (existing) return existing.id;
    const row = await db.one<{ id: string }>(
      "insert into applications (user_id, job_id, stage, checklist) values ($1, $2, $3, $4) returning id",
      [userId, jobId, stage, JSON.stringify(DEFAULT_CHECKLIST)],
    );
    await db.query("insert into application_events (user_id, application_id, from_stage, to_stage) values ($1, $2, null, $3)", [userId, row!.id, stage]);
    if (job.closes_on && job.closes_on >= today) {
      await insertTasks(db, userId, row!.id, [
        { kind: "application_deadline", title: `Apply to ${job.company} before the closing date`, due_on: applicationDeadlineDueDate(job.closes_on, today) },
      ]);
    }
    return row!.id;
  });
}

export type StageChangeResult = { ok: true } | { ok: false; error: string };

export async function changeStage(userId: string, applicationId: string, to: Stage, today: ISODate, note = ""): Promise<StageChangeResult> {
  return withUser(userId, async (db) => {
    const app = await db.one<{ stage: Stage; applied_on: string | null; follow_up_on: string | null; offer_deadline: string | null; company: string }>(
      `select a.stage, to_char(a.applied_on, 'YYYY-MM-DD') as applied_on, to_char(a.follow_up_on, 'YYYY-MM-DD') as follow_up_on,
              to_char(a.offer_deadline, 'YYYY-MM-DD') as offer_deadline, j.company
         from applications a join jobs j on j.id = a.job_id where a.id = $1 and a.user_id = $2 for update of a`,
      [applicationId, userId],
    );
    if (!app) return { ok: false, error: "Application not found." };
    const settings = await db.one<{ follow_up_after_days: number }>("select follow_up_after_days from user_settings where user_id = $1", [userId]);
    const plan = planTransition({
      from: app.stage,
      to,
      today,
      followUpAfterDays: settings?.follow_up_after_days ?? 7,
      application: app,
      company: app.company,
    });
    if (!plan.ok) return plan;

    await db.query(
      `update applications set stage = $3, stage_changed_at = now(),
              applied_on = coalesce($4::date, applied_on),
              follow_up_on = case when $5::boolean then $6::date else follow_up_on end
        where id = $1 and user_id = $2`,
      [applicationId, userId, plan.updates.stage, plan.updates.applied_on ?? null, "follow_up_on" in plan.updates, plan.updates.follow_up_on ?? null],
    );
    await db.query(
      "insert into application_events (user_id, application_id, from_stage, to_stage, note) values ($1, $2, $3, $4, $5)",
      [userId, applicationId, plan.event.from_stage, plan.event.to_stage, note],
    );
    if (plan.closeOpenReminders) {
      await db.query(
        "update tasks set completed_at = now() where user_id = $1 and application_id = $2 and completed_at is null and kind <> 'custom'",
        [userId, applicationId],
      );
    }
    await insertTasks(db, userId, applicationId, plan.tasks);
    return { ok: true };
  });
}

export type ApplicationDetailsInput = {
  resume_version_id: string | null;
  applied_on: string | null;
  next_action: string;
  next_action_on: string | null;
  follow_up_on: string | null;
  salary_expectation: string;
  rejection_reason: string;
  offer_details: string;
  offer_deadline: string | null;
  notes: string;
};

export async function updateApplicationDetails(userId: string, id: string, d: ApplicationDetailsInput, today: ISODate) {
  return withUser(userId, async (db) => {
    const before = await db.one<{ follow_up_on: string | null; offer_deadline: string | null; stage: Stage; company: string }>(
      `select to_char(a.follow_up_on, 'YYYY-MM-DD') as follow_up_on, to_char(a.offer_deadline, 'YYYY-MM-DD') as offer_deadline, a.stage, j.company
         from applications a join jobs j on j.id = a.job_id where a.id = $1 and a.user_id = $2`,
      [id, userId],
    );
    if (!before) return false;
    // The resume version must belong to this user; RLS and the composite FK also enforce this.
    const versionId = d.resume_version_id
      ? ((await db.one<{ id: string }>("select id from resume_versions where id = $1 and user_id = $2", [d.resume_version_id, userId]))?.id ?? null)
      : null;
    await db.query(
      `update applications set resume_version_id = $3, applied_on = $4, next_action = $5, next_action_on = $6, follow_up_on = $7,
              salary_expectation = $8, rejection_reason = $9, offer_details = $10, offer_deadline = $11, notes = $12
        where id = $1 and user_id = $2`,
      [id, userId, versionId, d.applied_on, d.next_action, d.next_action_on, d.follow_up_on, d.salary_expectation,
        d.rejection_reason, d.offer_details, d.offer_deadline, d.notes],
    );
    if (d.follow_up_on && d.follow_up_on !== before.follow_up_on && d.follow_up_on >= today) {
      await insertTasks(db, userId, id, [{ kind: "follow_up", title: `Follow up on your ${before.company} application`, due_on: d.follow_up_on }]);
    }
    if (d.offer_deadline && d.offer_deadline !== before.offer_deadline && before.stage === "offer") {
      const due = d.offer_deadline > today ? d.offer_deadline : today;
      await insertTasks(db, userId, id, [{ kind: "offer_deadline", title: `Decide on the ${before.company} offer`, due_on: due }]);
    }
    return true;
  });
}

export async function updateChecklist(userId: string, id: string, checklist: ChecklistItem[]) {
  await withUser(userId, (db) => db.query("update applications set checklist = $3 where id = $1 and user_id = $2", [id, userId, JSON.stringify(checklist)]));
}

export async function updateSelectedEvidence(userId: string, id: string, evidenceIds: string[]) {
  await withUser(userId, async (db) => {
    const owned = await db.query<{ id: string }>("select id from evidence_items where user_id = $1 and id = any($2::uuid[])", [userId, evidenceIds]);
    await db.query("update applications set selected_evidence_ids = $3 where id = $1 and user_id = $2", [id, userId, owned.map((r) => r.id)]);
  });
}

export async function deleteApplication(userId: string, id: string) {
  await withUser(userId, (db) => db.query("delete from applications where id = $1 and user_id = $2", [id, userId]));
}

export type ApplicationEvent = { id: string; from_stage: Stage | null; to_stage: Stage; occurred_at: string; note: string };

export async function listEvents(userId: string, applicationId: string): Promise<ApplicationEvent[]> {
  return withUser(userId, (db) =>
    db.query<ApplicationEvent>(
      "select id, from_stage, to_stage, occurred_at, note from application_events where application_id = $1 and user_id = $2 order by occurred_at desc",
      [applicationId, userId],
    ),
  );
}

// ---------------------------------------------------------------------------
// Contacts
// ---------------------------------------------------------------------------

export type Contact = { id: string; name: string; role: string; email: string; phone: string; profile_url: string; notes: string };

export async function listContacts(userId: string, applicationId: string): Promise<Contact[]> {
  return withUser(userId, (db) =>
    db.query<Contact>("select id, name, role, email, phone, profile_url, notes from contacts where application_id = $1 and user_id = $2 order by created_at", [applicationId, userId]),
  );
}

export async function addContact(userId: string, applicationId: string, c: Omit<Contact, "id">) {
  await withUser(userId, (db) =>
    db.query(
      `insert into contacts (user_id, application_id, name, role, email, phone, profile_url, notes)
       select $1, id, $3, $4, $5, $6, $7, $8 from applications where id = $2 and user_id = $1`,
      [userId, applicationId, c.name, c.role, c.email, c.phone, c.profile_url, c.notes],
    ),
  );
}

export async function deleteContact(userId: string, contactId: string) {
  await withUser(userId, (db) => db.query("delete from contacts where id = $1 and user_id = $2", [contactId, userId]));
}

// ---------------------------------------------------------------------------
// Interviews
// ---------------------------------------------------------------------------

export type Interview = {
  id: string;
  application_id: string;
  scheduled_at: string;
  kind: string;
  interviewers: string;
  location: string;
  notes: string;
  reflection: string;
  company: string;
  job_title: string;
  stage: Stage;
};

const INTERVIEW_COLUMNS = `i.id, i.application_id, i.scheduled_at, i.kind, i.interviewers, i.location, i.notes, i.reflection,
  j.company, j.title as job_title, a.stage`;

export async function listInterviews(userId: string, applicationId?: string): Promise<Interview[]> {
  return withUser(userId, (db) =>
    db.query<Interview>(
      `select ${INTERVIEW_COLUMNS} from interviews i join applications a on a.id = i.application_id join jobs j on j.id = a.job_id
        where i.user_id = $1 and ($2::uuid is null or i.application_id = $2) order by i.scheduled_at`,
      [userId, applicationId ?? null],
    ),
  );
}

export async function scheduleInterview(
  userId: string,
  applicationId: string,
  input: { scheduled_at: string; date: ISODate; kind: string; interviewers: string; location: string; notes: string },
  today: ISODate,
): Promise<boolean> {
  return withUser(userId, async (db) => {
    const app = await db.one<{ company: string }>(
      "select j.company from applications a join jobs j on j.id = a.job_id where a.id = $1 and a.user_id = $2",
      [applicationId, userId],
    );
    if (!app) return false;
    const row = await db.one<{ id: string }>(
      `insert into interviews (user_id, application_id, scheduled_at, kind, interviewers, location, notes)
       values ($1, $2, $3, $4, $5, $6, $7) returning id`,
      [userId, applicationId, input.scheduled_at, input.kind, input.interviewers, input.location, input.notes],
    );
    if (input.date >= today) {
      await insertTasks(
        db, userId, applicationId,
        [{ kind: "interview_prep", title: `Prepare for your ${app.company} interview`, due_on: interviewPrepDueDate(input.date, today) }],
        row!.id,
      );
    }
    return true;
  });
}

export async function updateInterviewNotes(userId: string, interviewId: string, notes: string, reflection: string) {
  await withUser(userId, (db) =>
    db.query("update interviews set notes = $3, reflection = $4 where id = $1 and user_id = $2", [interviewId, userId, notes, reflection]),
  );
}

export async function deleteInterview(userId: string, interviewId: string) {
  await withUser(userId, (db) => db.query("delete from interviews where id = $1 and user_id = $2", [interviewId, userId]));
}

// ---------------------------------------------------------------------------
// Generated documents
// ---------------------------------------------------------------------------

export type GeneratedDocument<T> = { id: string; content: T; warnings: unknown; provider: string; model: string; prompt_version: string; created_at: string };

export async function saveGeneratedDocument(
  userId: string,
  applicationId: string,
  kind: "application_materials" | "interview_prep",
  content: unknown,
  warnings: unknown,
  meta: { provider: string; model: string; prompt_version: string },
) {
  await withUser(userId, (db) =>
    db.query(
      `insert into generated_documents (user_id, application_id, kind, content, warnings, provider, model, prompt_version)
       select $1, id, $3, $4, $5, $6, $7, $8 from applications where id = $2 and user_id = $1`,
      [userId, applicationId, kind, JSON.stringify(content), JSON.stringify(warnings), meta.provider, meta.model, meta.prompt_version],
    ),
  );
}

export async function getLatestDocument<T>(userId: string, applicationId: string, kind: "application_materials" | "interview_prep"): Promise<GeneratedDocument<T> | null> {
  return withUser(userId, (db) =>
    db.one<GeneratedDocument<T>>(
      `select id, content, warnings, provider, model, prompt_version, created_at from generated_documents
        where application_id = $1 and user_id = $2 and kind = $3 order by created_at desc limit 1`,
      [applicationId, userId, kind],
    ),
  );
}

export async function updateDocumentContent(userId: string, documentId: string, content: unknown) {
  await withUser(userId, (db) =>
    db.query("update generated_documents set content = $3 where id = $1 and user_id = $2", [documentId, userId, JSON.stringify(content)]),
  );
}
