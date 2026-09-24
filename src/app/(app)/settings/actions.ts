"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { deleteAuthUser, requireUser } from "@/lib/auth";
import { listStoragePaths } from "@/lib/data/account";
import { saveSettings } from "@/lib/data/profile";
import { bool, fieldErrors, intOrNull, str, type ActionState } from "@/lib/forms";
import { deleteAllUserFiles } from "@/lib/storage";
import { settingsSchema } from "@/lib/validation";

export async function saveSettingsAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  const parsed = settingsSchema.safeParse({
    weekly_application_goal: intOrNull(fd, "weekly_application_goal") ?? 0,
    follow_up_after_days: intOrNull(fd, "follow_up_after_days") ?? 7,
    ai_assistance_enabled: bool(fd, "ai_assistance_enabled"),
  });
  if (!parsed.success) return { error: "Please fix the highlighted fields.", fieldErrors: fieldErrors(parsed.error) };
  await saveSettings(user.id, parsed.data);
  revalidatePath("/", "layout");
  return { ok: true, message: "Settings saved." };
}

/** Permanently deletes the account: files first, then the auth user (all rows cascade). */
export async function deleteAccountAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  if (str(fd, "confirm_email").toLowerCase() !== user.email.toLowerCase()) {
    return { error: "Type your account email exactly to confirm." };
  }
  const paths = await listStoragePaths(user.id);
  await deleteAllUserFiles(user.id, paths);
  await deleteAuthUser(user.id);
  redirect("/?deleted=1");
}
