import "server-only";
import { withUser } from "../db";

export type EvidenceItem = {
  id: string;
  title: string;
  organization: string;
  situation: string;
  action: string;
  result: string;
  skills: string[];
  metric: string;
  source: "resume" | "user_entered" | "interview_reflection";
  source_employment_id: string | null;
  confidence: "high" | "medium" | "low";
  verification_status: "verified" | "unverified" | "rejected";
  notes: string;
  created_at: string;
  updated_at: string;
};

export type EvidenceInput = Omit<EvidenceItem, "id" | "created_at" | "updated_at" | "source_employment_id"> & {
  source_employment_id?: string | null;
};

const COLUMNS = `id, title, organization, situation, action, result, skills, metric, source, source_employment_id,
                 confidence, verification_status, notes, created_at, updated_at`;

export async function listEvidence(userId: string): Promise<EvidenceItem[]> {
  return withUser(userId, (db) =>
    db.query<EvidenceItem>(
      `select ${COLUMNS} from evidence_items where user_id = $1
        order by case verification_status when 'unverified' then 0 when 'verified' then 1 else 2 end, updated_at desc`,
      [userId],
    ),
  );
}

export async function getEvidence(userId: string, id: string): Promise<EvidenceItem | null> {
  return withUser(userId, (db) => db.one<EvidenceItem>(`select ${COLUMNS} from evidence_items where id = $1 and user_id = $2`, [id, userId]));
}

export async function createEvidence(userId: string, e: EvidenceInput): Promise<string> {
  return withUser(userId, async (db) => {
    const row = await db.one<{ id: string }>(
      `insert into evidence_items (user_id, title, organization, situation, action, result, skills, metric, source,
                                   source_employment_id, confidence, verification_status, notes)
       values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) returning id`,
      [userId, e.title, e.organization, e.situation, e.action, e.result, e.skills, e.metric, e.source,
        e.source_employment_id ?? null, e.confidence, e.verification_status, e.notes],
    );
    return row!.id;
  });
}

export async function updateEvidence(userId: string, id: string, e: EvidenceInput) {
  return withUser(userId, (db) =>
    db.one(
      `update evidence_items set title = $3, organization = $4, situation = $5, action = $6, result = $7, skills = $8,
              metric = $9, confidence = $10, verification_status = $11, notes = $12
        where id = $1 and user_id = $2 returning id`,
      [id, userId, e.title, e.organization, e.situation, e.action, e.result, e.skills, e.metric, e.confidence, e.verification_status, e.notes],
    ),
  );
}

export async function setEvidenceStatus(userId: string, id: string, status: EvidenceItem["verification_status"]) {
  await withUser(userId, (db) => db.query("update evidence_items set verification_status = $3 where id = $1 and user_id = $2", [id, userId, status]));
}

export async function deleteEvidence(userId: string, id: string) {
  await withUser(userId, (db) => db.query("delete from evidence_items where id = $1 and user_id = $2", [id, userId]));
}

/**
 * Creates unverified evidence drafts from the achievements on the primary
 * resume, copied word for word. Metrics are only filled when the bullet itself
 * contains a number. Skips achievements that already have an evidence item.
 */
export async function importEvidenceFromResume(userId: string): Promise<number> {
  return withUser(userId, async (db) => {
    const rows = await db.query<{ id: string; employer: string; title: string; achievements: string[] }>(
      `select e.id, e.employer, e.title, e.achievements from employment_entries e
         join resumes r on r.id = e.resume_id and r.is_primary
        where e.user_id = $1 order by e.position`,
      [userId],
    );
    const existing = new Set(
      (await db.query<{ action: string }>("select action from evidence_items where user_id = $1", [userId])).map((r) => r.action.trim().toLowerCase()),
    );
    let created = 0;
    for (const role of rows) {
      for (const achievement of role.achievements) {
        const text = achievement.trim();
        if (!text || existing.has(text.toLowerCase())) continue;
        const metric = text.match(/(?:[$£€]\s?)?\d+(?:[.,]\d+)?\s*(?:%|percent|x\b|k\b|m\b|million|billion|\+)?(?:\s+[a-z]+){0,3}/i)?.[0]?.trim() ?? "";
        const title = text.split(/\s+/).slice(0, 8).join(" ").replace(/[,.;:]$/, "");
        await db.query(
          `insert into evidence_items (user_id, title, organization, action, metric, source, source_employment_id, confidence, verification_status, notes)
           values ($1, $2, $3, $4, $5, 'resume', $6, 'high', 'unverified', $7)`,
          [userId, title, role.employer, text, metric, role.id, `Imported from your resume (${role.title}). Add the situation and result, then mark as verified.`],
        );
        existing.add(text.toLowerCase());
        created++;
      }
    }
    return created;
  });
}
