import type { Metadata } from "next";
import Link from "next/link";
import { ArrowRight } from "lucide-react";
import { FitScore } from "@/components/badges";
import { ButtonLink } from "@/components/ui/button";
import { Alert, Card, CardHeader } from "@/components/ui/display";
import { INTERVIEW_KIND_LABELS } from "@/lib/domain";
import { formatDate, relativeDay } from "@/lib/dates";
import { loadTodayState } from "@/lib/data/insights";
import { todayForUser, userTimeZone } from "@/lib/server-date";
import { requireOnboardedUser } from "@/lib/session";
import { buildTodayPlan } from "@/lib/today";
import { CompleteTaskButton } from "../reminders/task-buttons";

export const metadata: Metadata = { title: "Today" };

function Empty({ children }: { children: React.ReactNode }) {
  return <p className="text-sm text-muted">{children}</p>;
}

export default async function TodayPage({ searchParams }: { searchParams: Promise<{ welcome?: string }> }) {
  const { user, profile } = await requireOnboardedUser();
  const [today, tz] = await Promise.all([todayForUser(), userTimeZone()]);
  const state = await loadTodayState(user.id, today, tz);
  const plan = buildTodayPlan(state);
  const { welcome } = await searchParams;
  const firstName = profile.full_name.split(" ")[0];
  const weeklyPct = plan.weekly.goal > 0 ? Math.min(100, Math.round((plan.weekly.applied / plan.weekly.goal) * 100)) : 0;

  return (
    <>
      <header className="mb-6">
        <p className="text-sm text-muted">{formatDate(today)}</p>
        <h1 className="text-2xl font-semibold">{firstName ? `What to do today, ${firstName}` : "What to do today"}</h1>
      </header>

      {welcome && !state.hasResume && (
        <Alert tone="accent" title="Step 2 of 2 · Add your resume" className="mb-6">
          <p>Fit analysis and application drafts are built only from your resume and evidence. Upload a PDF or DOCX, or paste the text.</p>
          <div className="mt-3">
            <ButtonLink href="/resumes/new" size="sm">Add resume</ButtonLink>
          </div>
        </Alert>
      )}

      <section aria-labelledby="priorities" className="mb-6">
        <h2 id="priorities" className="mb-3 text-sm font-semibold uppercase tracking-wide text-muted">Top priorities</h2>
        {plan.priorities.length === 0 ? (
          <Card>
            <p className="text-sm">Nothing urgent. A good day to find and analyse a new role.</p>
            <div className="mt-3">
              <ButtonLink href="/jobs/new" size="sm" variant="secondary">Save a job</ButtonLink>
            </div>
          </Card>
        ) : (
          <ol className="grid gap-3 md:grid-cols-3">
            {plan.priorities.map((p, i) => (
              <li key={p.key}>
                <Link href={p.href} className="group flex h-full flex-col rounded-lg border border-line bg-surface p-4 hover:border-accent">
                  <span className="text-xs font-semibold text-accent">{i + 1}</span>
                  <span className="mt-1 font-medium">{p.title}</span>
                  <span className="mt-1 text-sm text-muted">{p.detail}</span>
                  <span className="mt-auto inline-flex items-center gap-1 pt-3 text-sm font-medium text-accent">
                    Open <ArrowRight className="h-3.5 w-3.5 transition-transform group-hover:translate-x-0.5" aria-hidden />
                  </span>
                </Link>
              </li>
            ))}
          </ol>
        )}
      </section>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card aria-labelledby="overdue-h">
          <CardHeader title={<span id="overdue-h">Overdue and due today</span>} action={<Link href="/reminders" className="text-sm text-accent hover:underline">All reminders</Link>} />
          {plan.overdueTasks.length === 0 && plan.dueTodayTasks.length === 0 ? (
            <Empty>You are up to date.</Empty>
          ) : (
            <ul className="divide-y divide-line">
              {[...plan.overdueTasks, ...plan.dueTodayTasks].map((t) => (
                <li key={t.id} className="flex items-center justify-between gap-3 py-2">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium">{t.title}</p>
                    <p className={`text-xs ${t.due_on < today ? "text-danger" : "text-muted"}`}>Due {relativeDay(t.due_on, today)}</p>
                  </div>
                  <CompleteTaskButton id={t.id} />
                </li>
              ))}
            </ul>
          )}
        </Card>

        <Card aria-labelledby="follow-h">
          <CardHeader title={<span id="follow-h">Follow-ups due</span>} />
          {plan.followUps.length === 0 ? (
            <Empty>No applications need a follow-up yet.</Empty>
          ) : (
            <ul className="divide-y divide-line">
              {plan.followUps.map((a) => (
                <li key={a.id} className="py-2">
                  <Link href={`/applications/${a.id}`} className="text-sm font-medium hover:underline">{a.company} · {a.job_title}</Link>
                  <p className="text-xs text-muted">Follow-up due {a.dueLabel}</p>
                </li>
              ))}
            </ul>
          )}
        </Card>

        <Card aria-labelledby="interviews-h">
          <CardHeader title={<span id="interviews-h">Upcoming interviews</span>} action={<Link href="/interviews" className="text-sm text-accent hover:underline">All interviews</Link>} />
          {plan.upcomingInterviews.length === 0 ? (
            <Empty>No interviews in the next seven days.</Empty>
          ) : (
            <ul className="divide-y divide-line">
              {plan.upcomingInterviews.map((i) => (
                <li key={i.id} className="flex items-center justify-between gap-3 py-2">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium">{i.company} · {INTERVIEW_KIND_LABELS[i.kind as keyof typeof INTERVIEW_KIND_LABELS] ?? i.kind}</p>
                    <p className="text-xs text-muted">
                      {relativeDay(i.date, today)} at {new Date(i.scheduled_at).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: tz })}
                    </p>
                  </div>
                  <ButtonLink href={`/applications/${i.application_id}/interview`} size="sm" variant="secondary">Prepare</ButtonLink>
                </li>
              ))}
            </ul>
          )}
        </Card>

        <Card aria-labelledby="highfit-h">
          <CardHeader title={<span id="highfit-h">High-fit jobs awaiting application</span>} />
          {plan.highFitJobs.length === 0 ? (
            <Empty>Analyse saved jobs to find the ones worth applying for.</Empty>
          ) : (
            <ul className="divide-y divide-line">
              {plan.highFitJobs.map((j) => (
                <li key={j.id} className="flex items-center justify-between gap-3 py-2">
                  <div className="min-w-0">
                    <Link href={`/jobs/${j.id}`} className="block truncate text-sm font-medium hover:underline">{j.title}</Link>
                    <p className="text-xs text-muted">{j.company}{j.closes_on ? ` · closes ${relativeDay(j.closes_on, today)}` : ""}</p>
                  </div>
                  <FitScore score={j.fit?.score ?? null} />
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>

      <Card className="mt-4" aria-labelledby="week-h">
        <CardHeader title={<span id="week-h">This week</span>} description="Since Monday, from your recorded stage changes." />
        <div className="mb-3">
          <div className="flex justify-between text-sm">
            <span>Applications submitted</span>
            <span className="tabular-nums">{plan.weekly.applied} of {plan.weekly.goal} goal</span>
          </div>
          <div className="mt-1.5 h-2 rounded-full bg-subtle" role="progressbar" aria-valuemin={0} aria-valuemax={plan.weekly.goal} aria-valuenow={plan.weekly.applied} aria-label="Weekly application goal">
            <div className="h-2 rounded-full bg-accent" style={{ width: `${weeklyPct}%` }} />
          </div>
        </div>
        <dl className="grid grid-cols-3 gap-3 text-sm">
          <div><dt className="text-muted">Responses</dt><dd className="font-semibold tabular-nums">{plan.weekly.responses}</dd></div>
          <div><dt className="text-muted">Interviews</dt><dd className="font-semibold tabular-nums">{plan.weekly.interviews}</dd></div>
          <div><dt className="text-muted">Offers</dt><dd className="font-semibold tabular-nums">{plan.weekly.offers}</dd></div>
        </dl>
      </Card>
    </>
  );
}
