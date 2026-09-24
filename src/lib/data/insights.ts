import "server-only";
import { withUser } from "../db";
import type { AnalyticsApplication } from "../analytics";
import { addDays, isoDateInZone, type ISODate } from "../dates";
import type { TodayState } from "../today";

/** Loads everything the Today plan needs in one transaction. */
export async function loadTodayState(userId: string, today: ISODate, timeZone: string): Promise<TodayState> {
  return withUser(userId, async (db) => {
    const [resume, settings, jobs, applications, tasks, interviews, events] = await Promise.all([
      db.one("select 1 from resumes where user_id = $1 limit 1", [userId]),
      db.one<{ weekly_application_goal: number }>("select weekly_application_goal from user_settings where user_id = $1", [userId]),
      db.query<{ id: string; title: string; company: string; closes_on: string | null; score: number | null; recommendation: string | null; application_id: string | null; stage: string | null }>(
        `select j.id, j.title, j.company, to_char(j.closes_on, 'YYYY-MM-DD') as closes_on, f.score, f.recommendation, a.id as application_id, a.stage
           from jobs j
           left join lateral (select score, recommendation from fit_analyses fa where fa.job_id = j.id order by created_at desc limit 1) f on true
           left join applications a on a.job_id = j.id
          where j.user_id = $1`,
        [userId],
      ),
      db.query<TodayState["applications"][number]>(
        `select a.id, j.title as job_title, j.company, a.stage, to_char(a.follow_up_on, 'YYYY-MM-DD') as follow_up_on, a.next_action,
                to_char(a.next_action_on, 'YYYY-MM-DD') as next_action_on, to_char(a.offer_deadline, 'YYYY-MM-DD') as offer_deadline
           from applications a join jobs j on j.id = a.job_id where a.user_id = $1`,
        [userId],
      ),
      db.query<TodayState["tasks"][number]>(
        `select id, title, kind, to_char(due_on, 'YYYY-MM-DD') as due_on, application_id from tasks
          where user_id = $1 and completed_at is null and due_on <= $2 order by due_on`,
        [userId, addDays(today, 0)],
      ),
      db.query<{ id: string; application_id: string; scheduled_at: Date; kind: string; company: string; job_title: string }>(
        `select i.id, i.application_id, i.scheduled_at, i.kind, j.company, j.title as job_title
           from interviews i join applications a on a.id = i.application_id join jobs j on j.id = a.job_id
          where i.user_id = $1 and i.scheduled_at > now() - interval '8 days' and i.scheduled_at < now() + interval '9 days'`,
        [userId],
      ),
      db.query<{ to_stage: TodayState["recentEvents"][number]["to_stage"]; from_stage: TodayState["recentEvents"][number]["from_stage"]; occurred_at: Date }>(
        "select to_stage, from_stage, occurred_at from application_events where user_id = $1 and occurred_at > now() - interval '15 days'",
        [userId],
      ),
    ]);
    return {
      today,
      hasResume: Boolean(resume),
      weeklyGoal: settings?.weekly_application_goal ?? 5,
      jobs: jobs.map((j) => ({
        id: j.id,
        title: j.title,
        company: j.company,
        closes_on: j.closes_on,
        fit: j.score === null ? null : { score: j.score, recommendation: j.recommendation as "apply" },
        application: j.application_id ? { id: j.application_id, stage: j.stage as "interested" } : null,
      })),
      applications,
      tasks,
      interviews: interviews.map((i) => ({
        ...i,
        scheduled_at: new Date(i.scheduled_at).toISOString(),
        date: isoDateInZone(new Date(i.scheduled_at), timeZone),
      })),
      recentEvents: events.map((e) => ({ to_stage: e.to_stage, from_stage: e.from_stage, date: isoDateInZone(new Date(e.occurred_at), timeZone) })),
    };
  });
}

export async function loadAnalyticsData(userId: string): Promise<{ apps: AnalyticsApplication[]; targetRoles: string[] }> {
  return withUser(userId, async (db) => {
    const apps = await db.query<Omit<AnalyticsApplication, "events">>(
      `select a.id, a.stage, j.title as job_title, j.source, v.name as resume_version, a.rejection_reason, a.created_at
         from applications a join jobs j on j.id = a.job_id left join resume_versions v on v.id = a.resume_version_id
        where a.user_id = $1`,
      [userId],
    );
    const events = await db.query<{ application_id: string; from_stage: AnalyticsApplication["stage"] | null; to_stage: AnalyticsApplication["stage"]; occurred_at: Date }>(
      "select application_id, from_stage, to_stage, occurred_at from application_events where user_id = $1 order by occurred_at",
      [userId],
    );
    const roles = await db.query<{ title: string }>("select title from target_roles where user_id = $1 order by position", [userId]);
    const byApp = new Map<string, AnalyticsApplication["events"]>();
    for (const e of events) {
      const list = byApp.get(e.application_id) ?? [];
      list.push({ from_stage: e.from_stage, to_stage: e.to_stage, occurred_at: new Date(e.occurred_at).toISOString() });
      byApp.set(e.application_id, list);
    }
    return {
      apps: apps.map((a) => ({ ...a, created_at: new Date(a.created_at).toISOString(), events: byApp.get(a.id) ?? [] })),
      targetRoles: roles.map((r) => r.title),
    };
  });
}
