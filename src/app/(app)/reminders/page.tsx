import type { Metadata } from "next";
import Link from "next/link";
import { TaskForm } from "@/components/applications/workspace-forms";
import { Badge, Card, CardHeader, PageHeader } from "@/components/ui/display";
import { listTasks } from "@/lib/data/tasks";
import { addDays, relativeDay } from "@/lib/dates";
import { TASK_KIND_LABELS } from "@/lib/domain";
import { todayForUser } from "@/lib/server-date";
import { requireOnboardedUser } from "@/lib/session";
import { createTaskAction } from "./actions";
import { CompleteTaskButton, TaskMenu } from "./task-buttons";

export const metadata: Metadata = { title: "Reminders" };

export default async function RemindersPage() {
  const { user } = await requireOnboardedUser();
  const [tasks, today] = await Promise.all([listTasks(user.id, { includeCompleted: true }), todayForUser()]);
  const open = tasks.filter((t) => !t.completed_at);
  const done = tasks.filter((t) => t.completed_at).slice(0, 20);

  return (
    <>
      <PageHeader title="Reminders" description="Follow-ups, interview prep, deadlines and offer decisions are added automatically from your application dates. Add your own too." />
      <Card className="mb-4">
        <TaskForm action={createTaskAction} defaultDate={addDays(today, 1)} />
      </Card>
      <Card>
        <CardHeader title={`Open (${open.length})`} />
        {open.length === 0 ? <p className="text-sm text-muted">Nothing pending.</p> : (
          <ul className="-my-2 divide-y divide-line">
            {open.map((t) => (
              <li key={t.id} className="flex flex-wrap items-center justify-between gap-3 py-3">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">{t.title}</span>
                    <Badge>{TASK_KIND_LABELS[t.kind]}</Badge>
                  </div>
                  <p className={`text-sm ${t.due_on < today ? "text-danger" : "text-muted"}`}>
                    {t.due_on < today ? "Overdue · " : ""}Due {relativeDay(t.due_on, today)}
                    {t.application_id && <> · <Link href={`/applications/${t.application_id}`} className="text-accent hover:underline">{t.company}</Link></>}
                  </p>
                </div>
                <div className="flex flex-wrap items-center gap-1">
                  <TaskMenu id={t.id} />
                  <CompleteTaskButton id={t.id} />
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>
      {done.length > 0 && (
        <Card className="mt-4">
          <CardHeader title="Recently completed" />
          <ul className="-my-2 divide-y divide-line">
            {done.map((t) => (
              <li key={t.id} className="flex items-center justify-between gap-3 py-2 text-sm">
                <span className="text-muted line-through">{t.title}</span>
                <CompleteTaskButton id={t.id} completed />
              </li>
            ))}
          </ul>
        </Card>
      )}
    </>
  );
}
