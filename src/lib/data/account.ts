import "server-only";
import { withUser } from "../db";

const EXPORT_TABLES = [
  "profiles", "user_settings", "target_roles", "resumes", "employment_entries", "education_entries", "certifications",
  "skills", "projects", "evidence_items", "resume_versions", "jobs", "job_requirements", "fit_analyses", "fit_matches",
  "applications", "application_events", "contacts", "interviews", "tasks", "generated_documents",
] as const;

/** Everything stored for the user, read through RLS so it can only ever contain their rows. */
export async function exportUserData(userId: string, email: string) {
  return withUser(userId, async (db) => {
    const data: Record<string, unknown[]> = {};
    for (const table of EXPORT_TABLES) {
      data[table] = await db.query(`select * from ${table} where user_id = $1 order by created_at`, [userId]);
    }
    return { exported_at: new Date().toISOString(), format: "jobpilot-export-v1", account: { id: userId, email }, data };
  });
}

export async function listStoragePaths(userId: string): Promise<string[]> {
  return withUser(userId, async (db) =>
    (await db.query<{ storage_path: string }>("select storage_path from resumes where user_id = $1 and storage_path is not null", [userId])).map(
      (r) => r.storage_path,
    ),
  );
}
