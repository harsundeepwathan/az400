import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Client } from "pg";
import { withUser } from "@/lib/db";
import { changeStage, createApplication, getApplication } from "@/lib/data/applications";
import { createJob, deleteJob, getJob, listJobs, updateJob } from "@/lib/data/jobs";
import { exportUserData } from "@/lib/data/account";

/**
 * Runs against the configured DATABASE_URL (local mode). Verifies that user B
 * can never read, change or attach data to user A's records, both at the
 * database level (RLS + composite foreign keys) and through the data layer.
 */
const run = process.env.DATABASE_URL && (process.env.AUTH_MODE ?? "local") === "local";

describe.skipIf(!run)("authorisation boundaries", () => {
  const admin = new Client({ connectionString: process.env.DATABASE_URL });
  let userA = "";
  let userB = "";
  let jobA = "";
  const tag = `authz-${Date.now()}`;

  const job = {
    title: "Secret role", company: "A Corp", url: "", location: "", workplace_type: "unknown" as const, salary_min: null, salary_max: null,
    currency: "USD", description: "private", source: "", discovered_on: "2026-01-01", closes_on: null, contact_name: "", contact_email: "", notes: "private notes",
  };

  beforeAll(async () => {
    await admin.connect();
    const a = await admin.query("insert into auth.users (email) values ($1) returning id", [`a-${tag}@test.local`]);
    const b = await admin.query("insert into auth.users (email) values ($1) returning id", [`b-${tag}@test.local`]);
    userA = a.rows[0].id;
    userB = b.rows[0].id;
    await admin.query("insert into user_settings (user_id) values ($1), ($2)", [userA, userB]);
    jobA = await createJob(userA, job, [{ text: "Kubernetes", kind: "must" }]);
  });

  afterAll(async () => {
    await admin.query("delete from auth.users where id = any($1)", [[userA, userB]]);
    await admin.end();
  });

  it("RLS hides other users' rows even without a user_id filter", async () => {
    const rows = await withUser(userB, (db) => db.query("select id from jobs"));
    expect(rows.map((r) => r.id)).not.toContain(jobA);
    const own = await withUser(userA, (db) => db.query("select id from jobs"));
    expect(own.map((r) => r.id)).toContain(jobA);
  });

  it("RLS blocks updates and deletes of other users' rows", async () => {
    await withUser(userB, (db) => db.query("update jobs set notes = 'hacked' where id = $1", [jobA]));
    await withUser(userB, (db) => db.query("delete from jobs where id = $1", [jobA]));
    const row = await admin.query("select notes from jobs where id = $1", [jobA]);
    expect(row.rows[0].notes).toBe("private notes");
  });

  it("RLS blocks inserting rows owned by someone else", async () => {
    await expect(
      withUser(userB, (db) => db.query("insert into jobs (user_id, title, company) values ($1, 'x', 'y')", [userA])),
    ).rejects.toThrow(/row-level security/);
  });

  it("composite foreign keys stop attaching child rows to another user's parent", async () => {
    await expect(
      withUser(userB, (db) => db.query("insert into job_requirements (user_id, job_id, text, kind) values ($1, $2, 'x', 'must')", [userB, jobA])),
    ).rejects.toThrow(/foreign key/);
    await expect(
      withUser(userB, (db) => db.query("insert into applications (user_id, job_id) values ($1, $2)", [userB, jobA])),
    ).rejects.toThrow(/foreign key/);
  });

  it("the data layer returns nothing for another user's ids (no IDOR)", async () => {
    expect(await getJob(userB, jobA)).toBeNull();
    expect(await updateJob(userB, jobA, { ...job, title: "changed" })).toBeNull();
    await deleteJob(userB, jobA);
    expect(await getJob(userA, jobA)).not.toBeNull();
    expect(await createApplication(userB, jobA, "2026-01-02")).toBeNull();
    expect((await listJobs(userB)).length).toBe(0);
  });

  it("stage changes and application reads are scoped to the owner", async () => {
    const appA = await createApplication(userA, jobA, "2026-01-02");
    expect(appA).toBeTruthy();
    expect(await getApplication(userB, appA!)).toBeNull();
    expect(await changeStage(userB, appA!, "applied", "2026-01-03")).toEqual({ ok: false, error: "Application not found." });
    expect(await changeStage(userA, appA!, "applied", "2026-01-03")).toEqual({ ok: true });
    const events = await admin.query("select to_stage from application_events where application_id = $1 order by occurred_at", [appA]);
    expect(events.rows.map((r) => r.to_stage)).toEqual(["interested", "applied"]);
    const tasks = await admin.query("select kind, to_char(due_on, 'YYYY-MM-DD') as due_on from tasks where application_id = $1", [appA]);
    expect(tasks.rows).toContainEqual({ kind: "follow_up", due_on: "2026-01-10" });
  });

  it("application events are append-only for users", async () => {
    await expect(withUser(userA, (db) => db.query("update application_events set to_stage = 'offer'"))).rejects.toThrow(/permission denied/);
  });

  it("data export contains only the requesting user's data", async () => {
    const exportB = await exportUserData(userB, "b@test.local");
    expect(JSON.stringify(exportB)).not.toContain("private notes");
    const exportA = await exportUserData(userA, "a@test.local");
    expect(exportA.data.jobs).toHaveLength(1);
  });

  it("deleting an account removes all of its data", async () => {
    await admin.query("delete from auth.users where id = $1", [userA]);
    const left = await admin.query("select (select count(*) from jobs where user_id = $1) + (select count(*) from applications where user_id = $1) + (select count(*) from tasks where user_id = $1) as n", [userA]);
    expect(Number(left.rows[0].n)).toBe(0);
  });
});
