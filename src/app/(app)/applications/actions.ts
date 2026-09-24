"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { consumeAIQuota, providerForUser, PROMPT_VERSIONS, userMessageForAIError } from "@/lib/ai";
import { checkMaterials, checkPrep } from "@/lib/ai/postprocess";
import { materialsDraftSchema, prepDraftSchema, type Bullet } from "@/lib/ai/schemas";
import { isStage } from "@/lib/applications/stages";
import {
  addContact, changeStage, deleteApplication, deleteContact, deleteInterview, getApplication, getLatestDocument, listInterviews, saveGeneratedDocument,
  scheduleInterview, updateApplicationDetails, updateChecklist, updateDocumentContent, updateInterviewNotes, updateSelectedEvidence, type ChecklistItem,
} from "@/lib/data/applications";
import { getJob, getLatestFit, listRequirements } from "@/lib/data/jobs";
import { getCareerProfile } from "@/lib/data/resumes";
import { buildSources, yearsOfExperience } from "@/lib/fit/corpus";
import { detectInjectionSignals } from "@/lib/fit/requirements";
import { dateOrNull, fieldErrors, str, type ActionState } from "@/lib/forms";
import { todayForUser, userTimeZone } from "@/lib/server-date";
import { applicationDetailsSchema, contactSchema, interviewSchema, uuidSchema } from "@/lib/validation";

function refresh(id: string) {
  revalidatePath("/applications");
  revalidatePath(`/applications/${id}`);
  revalidatePath("/today");
  revalidatePath("/analytics");
  revalidatePath("/reminders");
  revalidatePath("/interviews");
}

const validId = (id: string) => uuidSchema.safeParse(id).success;

export async function changeStageAction(id: string, stage: string, note = ""): Promise<ActionState> {
  const user = await requireUser();
  if (!validId(id) || !isStage(stage)) return { error: "Invalid stage change." };
  const result = await changeStage(user.id, id, stage, await todayForUser(), note.slice(0, 500));
  if (!result.ok) return { error: result.error };
  refresh(id);
  return { ok: true };
}

export async function changeStageFormAction(id: string, _: ActionState, fd: FormData): Promise<ActionState> {
  return changeStageAction(id, str(fd, "stage"), str(fd, "note"));
}

export async function updateDetailsAction(id: string, _: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  if (!validId(id)) return { error: "Application not found." };
  const parsed = applicationDetailsSchema.safeParse({
    resume_version_id: str(fd, "resume_version_id") || null,
    applied_on: dateOrNull(fd, "applied_on"),
    next_action: str(fd, "next_action"),
    next_action_on: dateOrNull(fd, "next_action_on"),
    follow_up_on: dateOrNull(fd, "follow_up_on"),
    salary_expectation: str(fd, "salary_expectation"),
    rejection_reason: str(fd, "rejection_reason"),
    offer_details: str(fd, "offer_details"),
    offer_deadline: dateOrNull(fd, "offer_deadline"),
    notes: str(fd, "notes"),
  });
  if (!parsed.success) return { error: "Please fix the highlighted fields.", fieldErrors: fieldErrors(parsed.error) };
  const ok = await updateApplicationDetails(user.id, id, parsed.data, await todayForUser());
  if (!ok) return { error: "Application not found." };
  refresh(id);
  return { ok: true, message: "Saved." };
}

const checklistSchema = z.array(z.object({ label: z.string().min(1).max(200), done: z.boolean() })).max(30);

export async function updateChecklistAction(id: string, checklist: ChecklistItem[]) {
  const user = await requireUser();
  const parsed = checklistSchema.safeParse(checklist);
  if (!validId(id) || !parsed.success) return;
  await updateChecklist(user.id, id, parsed.data);
  revalidatePath(`/applications/${id}`);
}

export async function updateSelectedEvidenceAction(id: string, evidenceIds: string[]) {
  const user = await requireUser();
  const parsed = z.array(z.string().uuid()).max(50).safeParse(evidenceIds);
  if (!validId(id) || !parsed.success) return;
  await updateSelectedEvidence(user.id, id, parsed.data);
  revalidatePath(`/applications/${id}`);
}

export async function deleteApplicationAction(id: string) {
  const user = await requireUser();
  if (!validId(id)) return;
  await deleteApplication(user.id, id);
  revalidatePath("/applications");
  revalidatePath("/analytics");
  redirect("/applications");
}

export async function addContactAction(id: string, _: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  if (!validId(id)) return { error: "Application not found." };
  const parsed = contactSchema.safeParse({
    name: str(fd, "name"), role: str(fd, "role"), email: str(fd, "email"), phone: str(fd, "phone"), profile_url: str(fd, "profile_url"), notes: str(fd, "notes"),
  });
  if (!parsed.success) return { fieldErrors: fieldErrors(parsed.error) };
  await addContact(user.id, id, parsed.data);
  revalidatePath(`/applications/${id}`);
  return { ok: true, message: "Contact added." };
}

export async function deleteContactAction(applicationId: string, contactId: string) {
  const user = await requireUser();
  if (!validId(contactId)) return;
  await deleteContact(user.id, contactId);
  revalidatePath(`/applications/${applicationId}`);
}

/** Converts a wall-clock date and time in the user's time zone to an absolute timestamp. */
function zonedToUtc(date: string, time: string, timeZone: string): string {
  const guess = new Date(`${date}T${time}:00Z`);
  const parts = new Intl.DateTimeFormat("en-US", { timeZone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }).formatToParts(guess);
  const get = (t: string) => Number(parts.find((p) => p.type === t)?.value);
  const asZoned = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"));
  return new Date(guess.getTime() - (asZoned - guess.getTime())).toISOString();
}

export async function scheduleInterviewAction(id: string, _: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  if (!validId(id)) return { error: "Application not found." };
  const parsed = interviewSchema.safeParse({
    date: str(fd, "date"), time: str(fd, "time"), kind: str(fd, "kind"), interviewers: str(fd, "interviewers"), location: str(fd, "location"), notes: str(fd, "notes"),
  });
  if (!parsed.success) return { fieldErrors: fieldErrors(parsed.error) };
  const tz = await userTimeZone();
  const ok = await scheduleInterview(user.id, id, { ...parsed.data, scheduled_at: zonedToUtc(parsed.data.date, parsed.data.time, tz) }, await todayForUser());
  if (!ok) return { error: "Application not found." };
  refresh(id);
  return { ok: true, message: "Interview scheduled. A preparation reminder was added." };
}

export async function updateInterviewNotesAction(applicationId: string, interviewId: string, _: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  if (!validId(interviewId)) return { error: "Interview not found." };
  await updateInterviewNotes(user.id, interviewId, str(fd, "notes").slice(0, 10000), str(fd, "reflection").slice(0, 10000));
  revalidatePath(`/applications/${applicationId}/interview`);
  revalidatePath("/interviews");
  return { ok: true, message: "Notes saved." };
}

export async function deleteInterviewAction(applicationId: string, interviewId: string) {
  const user = await requireUser();
  if (!validId(interviewId)) return;
  await deleteInterview(user.id, interviewId);
  refresh(applicationId);
}

// ---------------------------------------------------------------------------
// AI-assisted drafting
// ---------------------------------------------------------------------------

async function loadContext(userId: string, applicationId: string) {
  const app = await getApplication(userId, applicationId);
  if (!app) return null;
  const [job, requirements, fit, career] = await Promise.all([
    getJob(userId, app.job_id),
    listRequirements(userId, app.job_id),
    getLatestFit(userId, app.job_id),
    getCareerProfile(userId),
  ]);
  if (!job) return null;
  return { app, job, requirements, fit, career };
}

export async function generateMaterialsAction(id: string): Promise<ActionState> {
  const user = await requireUser();
  if (!validId(id)) return { error: "Application not found." };
  const ctx = await loadContext(user.id, id);
  if (!ctx) return { error: "Application not found." };
  if (!ctx.career.resume) return { error: "Add a resume first." };
  if (!ctx.fit) return { error: "Run the fit analysis on this job first, so drafts can be based on verified matches." };

  const bullets: Bullet[] = ctx.career.employment.flatMap((e) => {
    const role = [e.title, e.employer].filter(Boolean).join(" at ");
    return [
      ...e.achievements.map((text, i) => ({ id: `${e.id}:a${i}`, employment_id: e.id, role, text })),
      ...e.responsibilities.map((text, i) => ({ id: `${e.id}:r${i}`, employment_id: e.id, role, text })),
    ];
  });
  const input = {
    job: { title: ctx.job.title, company: ctx.job.company, description: ctx.job.description, requirements: ctx.requirements },
    profile: { current_title: ctx.career.employment[0]?.title ?? "", years_experience: yearsOfExperience(ctx.career.employment), summary: ctx.career.resume.summary },
    supported: ctx.fit.matches
      .filter((m) => (m.match_type === "strong" || m.match_type === "transferable") && m.source_id && !m.needs_confirmation)
      .map((m) => ({ requirement: m.requirement_text, source_id: m.source_id!, source_label: m.source_label })),
    gaps: ctx.fit.matches.filter((m) => m.requirement_kind === "must" && m.match_type === "missing").map((m) => m.requirement_text),
    bullets,
    sources: buildSources(ctx.career),
  };

  const provider = await providerForUser(user.id);
  try {
    await consumeAIQuota(user.id, PROMPT_VERSIONS.materials);
    const draft = materialsDraftSchema.parse(await provider.applicationMaterials(input));
    const { materials, warnings } = checkMaterials(draft, input);
    const notes = detectInjectionSignals(ctx.job.description) ? ["The job description contained instruction-like text; it was ignored."] : [];
    await saveGeneratedDocument(user.id, id, "application_materials", materials, { claims: warnings, notes }, {
      provider: provider.name, model: provider.model, prompt_version: PROMPT_VERSIONS.materials,
    });
  } catch (error) {
    return { error: userMessageForAIError(error) };
  }
  revalidatePath(`/applications/${id}`);
  return { ok: true, message: "Drafts ready. Review every line before using them." };
}

const editableMaterials = z.object({ summary: z.string().max(3000), cover_letter: z.string().max(10000), outreach_message: z.string().max(3000) });

export async function saveMaterialsEditsAction(id: string, _: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  if (!validId(id)) return { error: "Application not found." };
  const doc = await getLatestDocument<Record<string, unknown>>(user.id, id, "application_materials");
  if (!doc) return { error: "Nothing to save yet." };
  const edits = editableMaterials.safeParse({ summary: str(fd, "summary"), cover_letter: str(fd, "cover_letter"), outreach_message: str(fd, "outreach_message") });
  if (!edits.success) return { error: "One of the texts is too long." };
  await updateDocumentContent(user.id, doc.id, { ...doc.content, ...edits.data, edited_by_user: true });
  revalidatePath(`/applications/${id}`);
  return { ok: true, message: "Your edits are saved." };
}

export async function generatePrepAction(id: string): Promise<ActionState> {
  const user = await requireUser();
  if (!validId(id)) return { error: "Application not found." };
  const ctx = await loadContext(user.id, id);
  if (!ctx) return { error: "Application not found." };
  const interviews = await listInterviews(user.id, id);
  const next = interviews.find((i) => new Date(i.scheduled_at) >= new Date()) ?? interviews.at(-1);
  const selected = new Set(ctx.app.selected_evidence_ids);
  const evidence = [...ctx.career.evidence]
    .filter((e) => e.verification_status !== "rejected")
    .sort((a, b) => Number(selected.has(b.id)) - Number(selected.has(a.id)))
    .map((e) => ({ id: e.id, title: e.title, situation: e.situation, action: e.action, result: e.result, verified: e.verification_status === "verified" }));
  const fitMatches = ctx.fit?.matches ?? [];
  const input = {
    job: { title: ctx.job.title, company: ctx.job.company, description: ctx.job.description, requirements: ctx.requirements },
    supported: fitMatches.filter((m) => m.match_type === "strong" || m.match_type === "transferable").map((m) => ({ requirement: m.requirement_text, source_label: m.source_label })),
    gaps: fitMatches.filter((m) => m.match_type === "missing" || (m.match_type === "unclear" && m.requirement_kind === "must")).map((m) => m.requirement_text),
    evidence,
    interview_kind: next?.kind ?? null,
  };
  const provider = await providerForUser(user.id);
  try {
    await consumeAIQuota(user.id, PROMPT_VERSIONS.prep);
    const draft = prepDraftSchema.parse(await provider.interviewPrep(input));
    const { prep, warnings } = checkPrep(draft, input);
    await saveGeneratedDocument(user.id, id, "interview_prep", prep, warnings, { provider: provider.name, model: provider.model, prompt_version: PROMPT_VERSIONS.prep });
  } catch (error) {
    return { error: userMessageForAIError(error) };
  }
  revalidatePath(`/applications/${id}/interview`);
  return { ok: true, message: "Preparation pack ready." };
}
