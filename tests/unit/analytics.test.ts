import { describe, expect, it } from "vitest";
import { averageDaysInStage, computeAnalytics, matchTargetRole, rate, type AnalyticsApplication } from "@/lib/analytics";
import type { Stage } from "@/lib/domain";

function app(id: string, path: Array<[Stage, string]>, extra: Partial<AnalyticsApplication> = {}): AnalyticsApplication {
  let from: Stage | null = null;
  const events = path.map(([to, date]) => {
    const e = { from_stage: from, to_stage: to, occurred_at: `${date}T10:00:00.000Z` };
    from = to;
    return e;
  });
  return { id, stage: path.at(-1)![0], job_title: "Platform Engineer", source: "LinkedIn", resume_version: null, rejection_reason: "", created_at: events[0]!.occurred_at, events, ...extra };
}

describe("rate", () => {
  it("reports raw counts and flags small samples", () => {
    expect(rate(0, 0)).toEqual({ numerator: 0, denominator: 0, percent: null, sample: "none" });
    expect(rate(3, 4)).toEqual({ numerator: 3, denominator: 4, percent: 75, sample: "insufficient" });
    expect(rate(3, 10).sample).toBe("early");
    expect(rate(10, 40)).toEqual({ numerator: 10, denominator: 40, percent: 25, sample: "reliable" });
  });
});

describe("computeAnalytics", () => {
  const apps = [
    app("a", [["interested", "2026-03-01"], ["applied", "2026-03-02"], ["recruiter_screen", "2026-03-09"], ["interview", "2026-03-16"], ["offer", "2026-03-30"]]),
    app("b", [["interested", "2026-03-01"], ["applied", "2026-03-03"], ["rejected", "2026-03-10"]], { rejection_reason: "Seniority" }),
    app("c", [["applied", "2026-03-04"]], { source: "Referral" }),
    // Skipped the screen: still counts as reaching screen and interview.
    app("d", [["applied", "2026-03-05"], ["interview", "2026-03-12"]]),
    // Never applied: excluded from conversion denominators.
    app("e", [["interested", "2026-03-06"]]),
  ];
  const result = computeAnalytics(apps, ["Platform Engineer"], "2026-04-01");

  it("counts conversions from stored events", () => {
    expect(result.totals).toMatchObject({ tracked: 5, submitted: 4, screened: 2, interviewed: 2, offers: 1 });
    expect(result.conversion.applicationToScreen).toMatchObject({ numerator: 2, denominator: 4, percent: 50, sample: "insufficient" });
    expect(result.conversion.screenToInterview).toMatchObject({ numerator: 2, denominator: 2, percent: 100 });
    expect(result.conversion.interviewToOffer).toMatchObject({ numerator: 1, denominator: 2, percent: 50 });
  });

  it("treats rejections after applying as responses", () => {
    expect(result.conversion.response).toMatchObject({ numerator: 3, denominator: 4 });
  });

  it("groups by week, role, source and rejection reason", () => {
    expect(result.byWeek.reduce((n, w) => n + w.count, 0)).toBe(4);
    expect(result.byRole).toEqual([expect.objectContaining({ key: "Platform Engineer", applied: 4 })]);
    expect(result.bySource.map((s) => [s.key, s.applied])).toEqual([["LinkedIn", 3], ["Referral", 1]]);
    expect(result.rejectionReasons).toEqual([{ reason: "Seniority", count: 1 }]);
    expect(result.pipeline.find((p) => p.stage === "interested")!.count).toBe(1);
  });

  it("averages completed stage durations only", () => {
    const applied = averageDaysInStage(apps).find((s) => s.stage === "applied")!;
    // a: 7 days, b: 7 days, d: 7 days; c is still in Applied and excluded.
    expect(applied).toEqual({ stage: "applied", days: 7, samples: 3 });
  });
});

describe("matchTargetRole", () => {
  it("matches when all significant words appear", () => {
    expect(matchTargetRole("Senior Site Reliability Engineer", ["Site Reliability Engineer"])).toBe("Site Reliability Engineer");
    expect(matchTargetRole("Data Analyst", ["Platform Engineer"])).toBe("Other roles");
  });
});
