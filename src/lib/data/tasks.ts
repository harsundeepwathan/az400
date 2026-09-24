import "server-only";
import { withUser } from "../db";
import type { TaskKind } from "../domain";

export type Task = {
  id: string;
  kind: TaskKind;
  title: string;
  due_on: string;
  completed_at: string | null;
  application_id: string | null;
  company: string | null;
  job_title: string | null;
};

export async function listTasks(userId: string, opts: { includeCompleted?: boolean } = {}): Promise<Task[]> {
  return withUser(userId, (db) =>
    db.query<Task>(
      `select t.id, t.kind, t.title, to_char(t.due_on, 'YYYY-MM-DD') as due_on, t.completed_at, t.application_id,
              j.company, j.title as job_title
         from tasks t left join applications a on a.id = t.application_id left join jobs j on j.id = a.job_id
        where t.user_id = $1 and ($2::boolean or t.completed_at is null)
        order by t.completed_at nulls first, t.due_on, t.created_at
        limit 200`,
      [userId, opts.includeCompleted ?? false],
    ),
  );
}

export async function createTask(userId: string, t: { title: string; due_on: string; application_id: string | null }) {
  await withUser(userId, async (db) => {
    const appId = t.application_id
      ? ((await db.one<{ id: string }>("select id from applications where id = $1 and user_id = $2", [t.application_id, userId]))?.id ?? null)
      : null;
    await db.query("insert into tasks (user_id, application_id, kind, title, due_on) values ($1, $2, 'custom', $3, $4)", [userId, appId, t.title, t.due_on]);
  });
}

export async function setTaskCompleted(userId: string, id: string, completed: boolean) {
  await withUser(userId, (db) =>
    db.query("update tasks set completed_at = case when $3 then now() else null end where id = $1 and user_id = $2", [id, userId, completed]),
  );
}

export async function snoozeTask(userId: string, id: string, dueOn: string) {
  await withUser(userId, (db) => db.query("update tasks set due_on = $3 where id = $1 and user_id = $2", [id, userId, dueOn]));
}

export async function deleteTask(userId: string, id: string) {
  await withUser(userId, (db) => db.query("delete from tasks where id = $1 and user_id = $2", [id, userId]));
}
