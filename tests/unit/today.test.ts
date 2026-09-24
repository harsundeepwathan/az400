import { describe, expect, it } from "vitest";
import { buildTodayPlan, type TodayState } from "@/lib/today";

const empty: TodayState = { today: "2026-03-11", hasResume: true, weeklyGoal: 5, jobs: [], applications: [], tasks: [], interviews: [], recentEvents: [] };

describe("buildTodayPlan", () => {
  it("guides a brand-new user to add a resume and a job", () => {
    const plan = buildTodayPlan({ ...empty, hasResume: false });
    expect(plan.priorities.map((p) => p.key)).toEqual(["resume", "job"]);
  });

  it("returns at most three priorities, most urgent first", () => {
    const plan = buildTodayPlan({
      ...empty,
      interviews: [{ id: "i1", application_id: "a1", scheduled_at: "2026-03-12T14:00:00Z", date: "2026-03-12", kind: "technical", company: "Acme", job_title: "SRE" }],
      tasks: [{ id: "t1", title: "Send references", kind: "custom", due_on: "2026-03-09", application_id: null }],
      applications: [
        { id: "a2", job_title: "Dev", company: "Beta", stage: "applied", follow_up_on: "2026-03-10", next_action: "", next_action_on: null, offer_deadline: null },
        { id: "a3", job_title: "Ops", company: "Gamma", stage: "applied", follow_up_on: "2026-03-20", next_action: "", next_action_on: null, offer_deadline: null },
      ],
      jobs: [{ id: "j1", title: "Platform", company: "Delta", closes_on: null, fit: { score: 80, recommendation: "strong_apply" }, application: null }],
    });
    expect(plan.priorities).toHaveLength(3);
    expect(plan.priorities.map((p) => p.key)).toEqual(["interview-i1", "task-t1", "follow-a2"]);
    expect(plan.followUps.map((f) => f.id)).toEqual(["a2"]);
    expect(plan.overdueTasks.map((t) => t.id)).toEqual(["t1"]);
    expect(plan.highFitJobs.map((j) => j.id)).toEqual(["j1"]);
  });

  it("does not list the same follow-up twice", () => {
    const plan = buildTodayPlan({
      ...empty,
      tasks: [{ id: "t1", title: "Follow up on your Beta application", kind: "follow_up", due_on: "2026-03-09", application_id: "a2" }],
      applications: [{ id: "a2", job_title: "Dev", company: "Beta", stage: "applied", follow_up_on: "2026-03-09", next_action: "", next_action_on: null, offer_deadline: null }],
    });
    expect(plan.priorities.map((p) => p.key).filter((k) => k !== "job")).toEqual(["task-t1"]);
  });

  it("excludes closed jobs and jobs already applied to from high-fit suggestions", () => {
    const plan = buildTodayPlan({
      ...empty,
      jobs: [
        { id: "closed", title: "x", company: "x", closes_on: "2026-03-01", fit: { score: 90, recommendation: "strong_apply" }, application: null },
        { id: "applied", title: "y", company: "y", closes_on: null, fit: { score: 90, recommendation: "strong_apply" }, application: { id: "a", stage: "applied" } },
        { id: "stretch", title: "z", company: "z", closes_on: null, fit: { score: 40, recommendation: "stretch" }, application: null },
      ],
    });
    expect(plan.highFitJobs).toEqual([]);
  });

  it("summarises the week from recorded events", () => {
    const plan = buildTodayPlan({
      ...empty,
      recentEvents: [
        { to_stage: "applied", from_stage: "preparing", date: "2026-03-09" },
        { to_stage: "applied", from_stage: "interested", date: "2026-03-11" },
        { to_stage: "applied", from_stage: "interested", date: "2026-03-06" },
        { to_stage: "recruiter_screen", from_stage: "applied", date: "2026-03-10" },
      ],
    });
    expect(plan.weekly).toMatchObject({ applied: 2, goal: 5, responses: 1 });
  });
});
