import { describe, expect, it } from "vitest";
import { interviewPrepDueDate, planTransition, type TransitionInput } from "@/lib/applications/stages";

const base: TransitionInput = {
  from: "preparing",
  to: "applied",
  today: "2026-03-10",
  followUpAfterDays: 7,
  application: { applied_on: null, follow_up_on: null, offer_deadline: null },
  company: "Acme",
};

describe("planTransition", () => {
  it("records the event and sets the application and follow-up dates when applying", () => {
    const plan = planTransition(base);
    expect(plan).toMatchObject({
      ok: true,
      updates: { stage: "applied", applied_on: "2026-03-10", follow_up_on: "2026-03-17" },
      event: { from_stage: "preparing", to_stage: "applied" },
      tasks: [{ kind: "follow_up", due_on: "2026-03-17" }],
      closeOpenReminders: false,
    });
  });

  it("does not overwrite an existing application date", () => {
    const plan = planTransition({ ...base, application: { ...base.application, applied_on: "2026-03-01" } });
    expect(plan.ok && plan.updates.applied_on).toBeUndefined();
  });

  it("rejects no-op and unknown transitions", () => {
    expect(planTransition({ ...base, from: "applied" })).toEqual({ ok: false, error: "Already in Applied." });
    expect(planTransition({ ...base, to: "hired" as never }).ok).toBe(false);
  });

  it("creates a recruiter-response reminder when moving to a screen", () => {
    const plan = planTransition({ ...base, from: "applied", to: "recruiter_screen" });
    expect(plan.ok && plan.tasks).toEqual([{ kind: "recruiter_response", title: expect.any(String), due_on: "2026-03-13" }]);
  });

  it("closes open reminders on rejection and clears the follow-up date", () => {
    const plan = planTransition({ ...base, from: "interview", to: "rejected" });
    expect(plan).toMatchObject({ ok: true, closeOpenReminders: true, updates: { follow_up_on: null }, tasks: [] });
  });

  it("schedules an offer-deadline reminder the day before the deadline", () => {
    const plan = planTransition({ ...base, from: "final_interview", to: "offer", application: { ...base.application, offer_deadline: "2026-03-20" } });
    expect(plan.ok && plan.tasks).toEqual([{ kind: "offer_deadline", title: expect.any(String), due_on: "2026-03-19" }]);
  });

  it("allows moving backwards to correct mistakes", () => {
    expect(planTransition({ ...base, from: "interview", to: "applied", application: { ...base.application, applied_on: "2026-03-01" } }).ok).toBe(true);
  });
});

describe("interviewPrepDueDate", () => {
  it("is the day before, but never in the past", () => {
    expect(interviewPrepDueDate("2026-03-15", "2026-03-10")).toBe("2026-03-14");
    expect(interviewPrepDueDate("2026-03-10", "2026-03-10")).toBe("2026-03-10");
  });
});
