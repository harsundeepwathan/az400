import { CLOSED_STAGES, PROGRESS_STAGES, STAGES, progressIndex, type Stage } from "./domain";
import { addDays, weekStart, type ISODate } from "./dates";

/**
 * Analytics computed purely from stored stage events. Rates always carry their
 * raw counts and a sample-size flag so small numbers are never over-read.
 */

export const MIN_SAMPLE = 5;
export const RELIABLE_SAMPLE = 20;

export type Rate = {
  numerator: number;
  denominator: number;
  /** Null when the denominator is zero. */
  percent: number | null;
  sample: "none" | "insufficient" | "early" | "reliable";
};

export function rate(numerator: number, denominator: number): Rate {
  if (denominator <= 0) return { numerator, denominator: 0, percent: null, sample: "none" };
  return {
    numerator,
    denominator,
    percent: Math.round((numerator / denominator) * 100),
    sample: denominator < MIN_SAMPLE ? "insufficient" : denominator < RELIABLE_SAMPLE ? "early" : "reliable",
  };
}

export type AnalyticsApplication = {
  id: string;
  stage: Stage;
  job_title: string;
  source: string;
  resume_version: string | null;
  rejection_reason: string;
  created_at: string;
  events: Array<{ from_stage: Stage | null; to_stage: Stage; occurred_at: string }>;
};

/** Furthest forward-progress stage an application ever reached. */
export function furthestStage(app: AnalyticsApplication): number {
  let max = -1;
  for (const e of app.events) max = Math.max(max, progressIndex(e.to_stage));
  return Math.max(max, progressIndex(app.stage));
}

const idx = (s: Stage) => progressIndex(s);

function reached(app: AnalyticsApplication, stage: Stage) {
  return furthestStage(app) >= idx(stage);
}

/** An application counts as submitted if it ever reached Applied or beyond, or was rejected after applying. */
export function wasSubmitted(app: AnalyticsApplication): boolean {
  if (reached(app, "applied")) return true;
  return app.events.some((e) => e.to_stage === "rejected" && e.from_stage !== null && progressIndex(e.from_stage) >= idx("applied"));
}

function appliedDate(app: AnalyticsApplication): ISODate | null {
  const e = app.events.find((ev) => progressIndex(ev.to_stage) >= idx("applied"));
  return e ? e.occurred_at.slice(0, 10) : null;
}

export function gotResponse(app: AnalyticsApplication): boolean {
  if (reached(app, "recruiter_screen")) return true;
  return app.events.some((e) => e.to_stage === "rejected");
}

export type GroupRow = { key: string; applied: number; screens: Rate; interviews: Rate };

function groupBy(apps: AnalyticsApplication[], keyOf: (a: AnalyticsApplication) => string): GroupRow[] {
  const groups = new Map<string, AnalyticsApplication[]>();
  for (const a of apps) {
    const k = keyOf(a);
    groups.set(k, [...(groups.get(k) ?? []), a]);
  }
  return [...groups.entries()]
    .map(([key, list]) => ({
      key,
      applied: list.length,
      screens: rate(list.filter((a) => reached(a, "recruiter_screen")).length, list.length),
      interviews: rate(list.filter((a) => reached(a, "interview")).length, list.length),
    }))
    .sort((a, b) => b.applied - a.applied);
}

export function matchTargetRole(jobTitle: string, targetRoles: string[]): string {
  const t = jobTitle.toLowerCase();
  const hit = targetRoles.find((r) => {
    const words = r.toLowerCase().split(/\s+/).filter((w) => w.length > 2);
    return words.length > 0 && words.every((w) => t.includes(w));
  });
  return hit ?? "Other roles";
}

export function averageDaysInStage(apps: AnalyticsApplication[]): Array<{ stage: Stage; days: number | null; samples: number }> {
  const totals = new Map<Stage, { sum: number; n: number }>();
  for (const app of apps) {
    const events = [...app.events].sort((a, b) => a.occurred_at.localeCompare(b.occurred_at));
    for (let i = 0; i < events.length - 1; i++) {
      const stage = events[i]!.to_stage;
      const ms = Date.parse(events[i + 1]!.occurred_at) - Date.parse(events[i]!.occurred_at);
      const t = totals.get(stage) ?? { sum: 0, n: 0 };
      totals.set(stage, { sum: t.sum + ms / 86_400_000, n: t.n + 1 });
    }
  }
  return PROGRESS_STAGES.map((stage) => {
    const t = totals.get(stage);
    return { stage, days: t ? Math.round((t.sum / t.n) * 10) / 10 : null, samples: t?.n ?? 0 };
  });
}

export function computeAnalytics(apps: AnalyticsApplication[], targetRoles: string[], today: ISODate, weeks = 12) {
  const submitted = apps.filter(wasSubmitted);
  const screened = submitted.filter((a) => reached(a, "recruiter_screen"));
  const interviewed = submitted.filter((a) => reached(a, "interview"));
  const offers = submitted.filter((a) => reached(a, "offer"));

  const firstWeek = addDays(weekStart(today), -7 * (weeks - 1));
  const byWeek: Array<{ week: ISODate; count: number }> = [];
  for (let i = 0; i < weeks; i++) byWeek.push({ week: addDays(firstWeek, 7 * i), count: 0 });
  for (const a of submitted) {
    const d = appliedDate(a);
    if (!d) continue;
    const bucket = byWeek.find((w) => w.week === weekStart(d));
    if (bucket) bucket.count++;
  }

  const rejectionReasons = new Map<string, number>();
  for (const a of apps.filter((x) => x.stage === "rejected")) {
    const reason = a.rejection_reason.trim() || "No reason recorded";
    rejectionReasons.set(reason, (rejectionReasons.get(reason) ?? 0) + 1);
  }

  return {
    totals: { tracked: apps.length, submitted: submitted.length, screened: screened.length, interviewed: interviewed.length, offers: offers.length },
    conversion: {
      applicationToScreen: rate(screened.length, submitted.length),
      screenToInterview: rate(interviewed.length, screened.length),
      interviewToOffer: rate(offers.length, interviewed.length),
      response: rate(submitted.filter(gotResponse).length, submitted.length),
    },
    byWeek,
    byRole: groupBy(submitted, (a) => matchTargetRole(a.job_title, targetRoles)),
    byResumeVersion: groupBy(submitted, (a) => a.resume_version ?? "No version recorded"),
    bySource: groupBy(submitted, (a) => a.source.trim() || "Unknown source"),
    rejectionReasons: [...rejectionReasons.entries()].map(([reason, count]) => ({ reason, count })).sort((a, b) => b.count - a.count),
    pipeline: STAGES.map((stage) => ({ stage, count: apps.filter((a) => a.stage === stage).length })),
    timeInStage: averageDaysInStage(apps),
    closedCount: apps.filter((a) => CLOSED_STAGES.includes(a.stage)).length,
  };
}

export type Analytics = ReturnType<typeof computeAnalytics>;
