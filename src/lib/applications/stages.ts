import { STAGES, STAGE_LABELS, type Stage, type TaskKind } from "../domain";
import { addDays, type ISODate } from "../dates";

export type TransitionInput = {
  from: Stage;
  to: Stage;
  today: ISODate;
  followUpAfterDays: number;
  application: { applied_on: ISODate | null; follow_up_on: ISODate | null; offer_deadline: ISODate | null };
  company: string;
};

export type PlannedTask = { kind: TaskKind; title: string; due_on: ISODate };

export type TransitionPlan =
  | { ok: false; error: string }
  | {
      ok: true;
      updates: { stage: Stage; applied_on?: ISODate; follow_up_on?: ISODate | null };
      event: { from_stage: Stage; to_stage: Stage };
      tasks: PlannedTask[];
      /** Close open automatic reminders (the application is no longer active). */
      closeOpenReminders: boolean;
    };

export function isStage(value: unknown): value is Stage {
  return typeof value === "string" && (STAGES as readonly string[]).includes(value);
}

/**
 * Pure planner for a stage change. Every change is recorded as an event so
 * analytics can be reconstructed; reminders are derived deterministically.
 */
export function planTransition(input: TransitionInput): TransitionPlan {
  const { from, to, today, application, company } = input;
  if (!isStage(to)) return { ok: false, error: "Unknown stage." };
  if (from === to) return { ok: false, error: `Already in ${STAGE_LABELS[to]}.` };

  const updates: { stage: Stage; applied_on?: ISODate; follow_up_on?: ISODate | null } = { stage: to };
  const tasks: PlannedTask[] = [];

  if (to === "applied") {
    if (!application.applied_on) updates.applied_on = today;
    const followUp = addDays(today, input.followUpAfterDays);
    if (!application.follow_up_on || application.follow_up_on < today) updates.follow_up_on = followUp;
    tasks.push({ kind: "follow_up", title: `Follow up on your ${company} application`, due_on: updates.follow_up_on ?? application.follow_up_on ?? followUp });
  }
  if (to === "recruiter_screen") {
    tasks.push({ kind: "recruiter_response", title: `Confirm next steps with the ${company} recruiter`, due_on: addDays(today, 3) });
  }
  if (to === "offer" && application.offer_deadline) {
    const due = addDays(application.offer_deadline, -1);
    tasks.push({ kind: "offer_deadline", title: `Decide on the ${company} offer`, due_on: due < today ? today : due });
  }

  const closeOpenReminders = to === "rejected" || to === "withdrawn" || to === "archived" || to === "offer";
  if (closeOpenReminders) updates.follow_up_on = null;

  return { ok: true, updates, event: { from_stage: from, to_stage: to }, tasks, closeOpenReminders };
}

export function interviewPrepDueDate(scheduledDate: ISODate, today: ISODate): ISODate {
  const due = addDays(scheduledDate, -1);
  return due < today ? today : due;
}

export function applicationDeadlineDueDate(closesOn: ISODate, today: ISODate): ISODate {
  const due = addDays(closesOn, -2);
  return due < today ? today : due;
}
