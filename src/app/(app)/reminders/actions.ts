"use server";

import { revalidatePath } from "next/cache";
import { requireUser } from "@/lib/auth";
import { createTask, deleteTask, setTaskCompleted, snoozeTask } from "@/lib/data/tasks";
import { addDays } from "@/lib/dates";
import { fieldErrors, str, type ActionState } from "@/lib/forms";
import { todayForUser } from "@/lib/server-date";
import { taskSchema, uuidSchema } from "@/lib/validation";

function refresh() {
  revalidatePath("/today");
  revalidatePath("/reminders");
}

export async function completeTaskAction(id: string, completed = true) {
  const user = await requireUser();
  if (!uuidSchema.safeParse(id).success) return;
  await setTaskCompleted(user.id, id, completed);
  refresh();
}

export async function snoozeTaskAction(id: string, days: number) {
  const user = await requireUser();
  if (!uuidSchema.safeParse(id).success || ![1, 3, 7].includes(days)) return;
  await snoozeTask(user.id, id, addDays(await todayForUser(), days));
  refresh();
}

export async function deleteTaskAction(id: string) {
  const user = await requireUser();
  if (!uuidSchema.safeParse(id).success) return;
  await deleteTask(user.id, id);
  refresh();
}

export async function createTaskAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  const parsed = taskSchema.safeParse({
    title: str(fd, "title"),
    due_on: str(fd, "due_on"),
    application_id: str(fd, "application_id") || null,
  });
  if (!parsed.success) return { fieldErrors: fieldErrors(parsed.error) };
  await createTask(user.id, parsed.data);
  refresh();
  if (parsed.data.application_id) revalidatePath(`/applications/${parsed.data.application_id}`);
  return { ok: true, message: "Reminder added." };
}
