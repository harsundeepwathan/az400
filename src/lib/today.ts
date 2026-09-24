import { ACTIVE_STAGES, type Recommendation, type Stage } from "./domain";
import { addDays, daysBetween, relativeDay, weekStart, type ISODate } from "./dates";

/**
 * Deterministic daily plan. Built only from stored dates and application
 * state; AI never decides what the user should do today.
 */

export type TodayState = {
  today: ISODate;
  hasResume: boolean;
  weeklyGoal: number;
  jobs: Array<{
    id: string;
    title: string;
    company: string;
    closes_on: ISODate | null;
    fit: { score: number; recommendation: Recommendation } | null;
    application: { id: string; stage: Stage } | null;
  }>;
  applications: Array<{
    id: string;
    job_title: string;
    company: string;
    stage: Stage;
    follow_up_on: ISODate | null;
    next_action: string;
    next_action_on: ISODate | null;
    offer_deadline: ISODate | null;
  }>;
  tasks: Array<{ id: string; title: string; kind: string; due_on: ISODate; application_id: string | null }>;
  interviews: Array<{ id: string; application_id: string; scheduled_at: string; date: ISODate; kind: string; company: string; job_title: string }>;
  /** Stage-change events in the last 14 days. */
  recentEvents: Array<{ to_stage: Stage; from_stage: Stage | null; date: ISODate }>;
};

export type PriorityAction = { key: string; title: string; detail: string; href: string; weight: number };

export type TodayPlan = {
  priorities: PriorityAction[];
  followUps: Array<TodayState["applications"][number] & { dueLabel: string }>;
  upcomingInterviews: TodayState["interviews"];
  highFitJobs: TodayState["jobs"];
  overdueTasks: Array<TodayState["tasks"][number] & { dueLabel: string }>;
  dueTodayTasks: TodayState["tasks"];
  weekly: { applied: number; goal: number; responses: number; interviews: number; offers: number };
};

const HIGH_FIT: Recommendation[] = ["strong_apply", "apply"];

export function buildTodayPlan(state: TodayState): TodayPlan {
  const { today } = state;
  const candidates: PriorityAction[] = [];

  const upcomingInterviews = state.interviews
    .filter((i) => i.date >= today && i.date <= addDays(today, 7))
    .sort((a, b) => a.scheduled_at.localeCompare(b.scheduled_at));
  for (const i of upcomingInterviews) {
    const days = daysBetween(today, i.date);
    if (days <= 2) {
      candidates.push({
        key: `interview-${i.id}`,
        title: `Prepare for your ${i.company} interview`,
        detail: `${i.job_title} · ${relativeDay(i.date, today)}`,
        href: `/applications/${i.application_id}/interview`,
        weight: 100 - days,
      });
    }
  }

  for (const a of state.applications) {
    if (a.stage === "offer" && a.offer_deadline && daysBetween(today, a.offer_deadline) <= 3) {
      candidates.push({
        key: `offer-${a.id}`,
        title: `Respond to the ${a.company} offer`,
        detail: `Deadline ${relativeDay(a.offer_deadline, today)}`,
        href: `/applications/${a.id}`,
        weight: 95,
      });
    }
  }

  const overdueTasks = state.tasks
    .filter((t) => t.due_on < today)
    .sort((a, b) => a.due_on.localeCompare(b.due_on))
    .map((t) => ({ ...t, dueLabel: relativeDay(t.due_on, today) }));
  for (const t of overdueTasks.slice(0, 2)) {
    candidates.push({
      key: `task-${t.id}`,
      title: t.title,
      detail: `Overdue · due ${t.dueLabel}`,
      href: t.application_id ? `/applications/${t.application_id}` : "/reminders",
      weight: 90,
    });
  }
  const dueTodayTasks = state.tasks.filter((t) => t.due_on === today);

  const followUps = state.applications
    .filter((a) => ACTIVE_STAGES.includes(a.stage) && a.stage !== "offer" && a.follow_up_on && a.follow_up_on <= today)
    .sort((a, b) => (a.follow_up_on ?? "").localeCompare(b.follow_up_on ?? ""))
    .map((a) => ({ ...a, dueLabel: relativeDay(a.follow_up_on!, today) }));
  // A follow-up already represented by an overdue reminder is not listed twice.
  const remindedApps = new Set(overdueTasks.slice(0, 2).map((t) => t.application_id).filter(Boolean));
  for (const a of followUps.filter((f) => !remindedApps.has(f.id)).slice(0, 2)) {
    candidates.push({
      key: `follow-${a.id}`,
      title: `Follow up with ${a.company}`,
      detail: `${a.job_title} · follow-up due ${a.dueLabel}`,
      href: `/applications/${a.id}`,
      weight: 80,
    });
  }

  for (const a of state.applications) {
    if (a.next_action && a.next_action_on && a.next_action_on <= today && !["rejected", "withdrawn", "archived"].includes(a.stage)) {
      candidates.push({
        key: `next-${a.id}`,
        title: a.next_action,
        detail: `${a.company} · ${a.job_title}`,
        href: `/applications/${a.id}`,
        weight: 75,
      });
    }
  }

  const highFitJobs = state.jobs
    .filter((j) => j.fit && HIGH_FIT.includes(j.fit.recommendation))
    .filter((j) => !j.application || j.application.stage === "interested" || j.application.stage === "preparing")
    .filter((j) => !j.closes_on || j.closes_on >= today)
    .sort((a, b) => {
      const ac = a.closes_on ?? "9999-12-31";
      const bc = b.closes_on ?? "9999-12-31";
      return ac.localeCompare(bc) || (b.fit?.score ?? 0) - (a.fit?.score ?? 0);
    });
  for (const j of highFitJobs.slice(0, 2)) {
    const closingSoon = j.closes_on && daysBetween(today, j.closes_on) <= 3;
    candidates.push({
      key: `job-${j.id}`,
      title: `Apply to ${j.company}`,
      detail: `${j.title} · fit ${j.fit!.score}${j.closes_on ? ` · closes ${relativeDay(j.closes_on, today)}` : ""}`,
      href: j.application ? `/applications/${j.application.id}` : `/jobs/${j.id}`,
      weight: closingSoon ? 85 : 60,
    });
  }

  const unanalysed = state.jobs.find((j) => !j.fit && !j.application);
  if (unanalysed && state.hasResume) {
    candidates.push({
      key: `analyse-${unanalysed.id}`,
      title: `Check your fit for ${unanalysed.title}`,
      detail: `${unanalysed.company} · not analysed yet`,
      href: `/jobs/${unanalysed.id}`,
      weight: 40,
    });
  }
  if (!state.hasResume) {
    candidates.push({ key: "resume", title: "Add your resume", detail: "Fit analysis needs your career profile", href: "/resumes/new", weight: 70 });
  }
  if (state.jobs.length === 0) {
    candidates.push({ key: "job", title: "Save a job you are interested in", detail: "Paste a job description to get started", href: "/jobs/new", weight: 65 });
  }

  const priorities = candidates.sort((a, b) => b.weight - a.weight).slice(0, 3);

  const start = weekStart(today);
  const thisWeek = state.recentEvents.filter((e) => e.date >= start && e.date <= today);
  const weekly = {
    applied: thisWeek.filter((e) => e.to_stage === "applied").length,
    goal: state.weeklyGoal,
    responses: thisWeek.filter((e) => e.from_stage === "applied" && e.to_stage !== "withdrawn" && e.to_stage !== "archived").length,
    interviews: state.interviews.filter((i) => i.date >= start && i.date <= addDays(start, 6)).length,
    offers: thisWeek.filter((e) => e.to_stage === "offer").length,
  };

  return {
    priorities,
    followUps: followUps.slice(0, 5),
    upcomingInterviews: upcomingInterviews.slice(0, 5),
    highFitJobs: highFitJobs.slice(0, 5),
    overdueTasks: overdueTasks.slice(0, 5),
    dueTodayTasks,
    weekly,
  };
}
