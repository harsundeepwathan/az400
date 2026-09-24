"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireUser } from "@/lib/auth";
import { createEvidence, deleteEvidence, getEvidence, setEvidenceStatus, updateEvidence } from "@/lib/data/evidence";
import { fieldErrors, list, str, type ActionState } from "@/lib/forms";
import { evidenceSchema, uuidSchema } from "@/lib/validation";

function parse(fd: FormData) {
  return evidenceSchema.safeParse({
    title: str(fd, "title"),
    organization: str(fd, "organization"),
    situation: str(fd, "situation"),
    action: str(fd, "action"),
    result: str(fd, "result"),
    skills: list(fd, "skills"),
    metric: str(fd, "metric"),
    confidence: str(fd, "confidence"),
    verification_status: str(fd, "verification_status"),
    notes: str(fd, "notes"),
  });
}

export async function saveEvidenceAction(id: string | null, _: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  const parsed = parse(fd);
  if (!parsed.success) return { error: "Please fix the highlighted fields.", fieldErrors: fieldErrors(parsed.error) };
  if (id) {
    if (!uuidSchema.safeParse(id).success) return { error: "Not found." };
    const existing = await getEvidence(user.id, id);
    if (!existing) return { error: "Not found." };
    await updateEvidence(user.id, id, { ...parsed.data, source: existing.source });
  } else {
    await createEvidence(user.id, { ...parsed.data, source: "user_entered" });
  }
  revalidatePath("/evidence");
  redirect("/evidence");
}

export async function setEvidenceStatusAction(id: string, status: "verified" | "unverified" | "rejected") {
  const user = await requireUser();
  if (!uuidSchema.safeParse(id).success) return;
  await setEvidenceStatus(user.id, id, status);
  revalidatePath("/evidence");
}

export async function deleteEvidenceAction(id: string) {
  const user = await requireUser();
  if (!uuidSchema.safeParse(id).success) return;
  await deleteEvidence(user.id, id);
  revalidatePath("/evidence");
  redirect("/evidence");
}
