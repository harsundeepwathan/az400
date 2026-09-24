"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireUser } from "@/lib/auth";
import { saveProfile } from "@/lib/data/profile";
import { bool, dateOrNull, fieldErrors, intOrNull, lines, str, type ActionState } from "@/lib/forms";
import { profileSchema } from "@/lib/validation";

function parseProfile(fd: FormData) {
  return profileSchema.safeParse({
    full_name: str(fd, "full_name"),
    current_title: str(fd, "current_title"),
    target_roles: lines(fd, "target_roles"),
    preferred_locations: lines(fd, "preferred_locations"),
    workplace_preference: str(fd, "workplace_preference"),
    target_salary: intOrNull(fd, "target_salary"),
    salary_currency: str(fd, "salary_currency").toUpperCase(),
    employment_types: fd.getAll("employment_types").map(String),
    willing_to_relocate: bool(fd, "willing_to_relocate"),
    work_authorization_notes: str(fd, "work_authorization_notes"),
    search_started_on: dateOrNull(fd, "search_started_on"),
  });
}

export async function completeOnboardingAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  const parsed = parseProfile(fd);
  if (!parsed.success) return { error: "Please fix the highlighted fields.", fieldErrors: fieldErrors(parsed.error) };
  await saveProfile(user.id, parsed.data, true);
  redirect("/today?welcome=1");
}

export async function updateProfileAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  const parsed = parseProfile(fd);
  if (!parsed.success) return { error: "Please fix the highlighted fields.", fieldErrors: fieldErrors(parsed.error) };
  await saveProfile(user.id, parsed.data, false);
  revalidatePath("/", "layout");
  return { ok: true, message: "Profile saved." };
}

