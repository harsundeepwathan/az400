"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { AIError, consumeAIQuota, providerForUser, PROMPT_VERSIONS, userMessageForAIError } from "@/lib/ai";
import { groundRequirements } from "@/lib/ai/postprocess";
import { createApplication } from "@/lib/data/applications";
import {
  addRequirement, createJob, deleteJob, deleteRequirement, getJob, listRequirements, replaceRequirements, saveFitAnalysis,
  updateJob, updateRequirementKind,
} from "@/lib/data/jobs";
import { getProfileBundle } from "@/lib/data/profile";
import { getCareerProfile } from "@/lib/data/resumes";
import { buildFitInput } from "@/lib/fit/build-input";
import { finalizeFit } from "@/lib/fit/finalize";
import { detectInjectionSignals, extractRequirements } from "@/lib/fit/requirements";
import { fitDraftSchema } from "@/lib/fit/types";
import { dateOrNull, fieldErrors, intOrNull, str, type ActionState } from "@/lib/forms";
import { todayForUser } from "@/lib/server-date";
import { jobSchema, uuidSchema } from "@/lib/validation";

async function parseJob(fd: FormData) {
  return jobSchema.safeParse({
    title: str(fd, "title"),
    company: str(fd, "company"),
    url: str(fd, "url"),
    location: str(fd, "location"),
    workplace_type: str(fd, "workplace_type") || "unknown",
    salary_min: intOrNull(fd, "salary_min"),
    salary_max: intOrNull(fd, "salary_max"),
    currency: (str(fd, "currency") || "USD").toUpperCase(),
    description: String(fd.get("description") ?? "").trim(),
    source: str(fd, "source"),
    discovered_on: str(fd, "discovered_on") || (await todayForUser()),
    closes_on: dateOrNull(fd, "closes_on"),
    contact_name: str(fd, "contact_name"),
    contact_email: str(fd, "contact_email"),
    notes: str(fd, "notes"),
  });
}

export async function saveJobAction(id: string | null, _: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  const parsed = await parseJob(fd);
  if (!parsed.success) return { error: "Please fix the highlighted fields.", fieldErrors: fieldErrors(parsed.error) };
  if (id) {
    if (!uuidSchema.safeParse(id).success || !(await updateJob(user.id, id, parsed.data))) return { error: "Job not found." };
    revalidatePath(`/jobs/${id}`);
    revalidatePath("/jobs");
    redirect(`/jobs/${id}`);
  }
  // Requirements are extracted deterministically on save; the user can edit them or re-extract with AI.
  const newId = await createJob(user.id, parsed.data, extractRequirements(parsed.data.description));
  revalidatePath("/jobs");
  redirect(`/jobs/${newId}?saved=1`);
}

export async function deleteJobAction(id: string) {
  const user = await requireUser();
  if (!uuidSchema.safeParse(id).success) return;
  await deleteJob(user.id, id);
  revalidatePath("/jobs");
  revalidatePath("/applications");
  redirect("/jobs");
}

export async function reextractRequirementsAction(jobId: string): Promise<ActionState> {
  const user = await requireUser();
  if (!uuidSchema.safeParse(jobId).success) return { error: "Job not found." };
  const job = await getJob(user.id, jobId);
  if (!job) return { error: "Job not found." };
  if (!job.description.trim()) return { error: "Add the job description first." };
  const provider = await providerForUser(user.id);
  let requirements = extractRequirements(job.description);
  if (provider.name !== "mock") {
    try {
      await consumeAIQuota(user.id, PROMPT_VERSIONS.requirements);
      const grounded = groundRequirements(await provider.extractRequirements(job.description), job.description).requirements;
      if (grounded.length > 0) requirements = grounded;
    } catch (error) {
      return { error: userMessageForAIError(error) };
    }
  }
  await replaceRequirements(user.id, jobId, requirements);
  revalidatePath(`/jobs/${jobId}`);
  return { ok: true, message: `Found ${requirements.length} requirement${requirements.length === 1 ? "" : "s"}. Re-run the analysis to use them.` };
}

const requirementInput = z.object({ text: z.string().trim().min(3, "Describe the requirement").max(400), kind: z.enum(["must", "nice"]) });

export async function addRequirementAction(jobId: string, _: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  if (!uuidSchema.safeParse(jobId).success) return { error: "Job not found." };
  const parsed = requirementInput.safeParse({ text: str(fd, "text"), kind: str(fd, "kind") });
  if (!parsed.success) return { fieldErrors: fieldErrors(parsed.error) };
  await addRequirement(user.id, jobId, parsed.data.text, parsed.data.kind);
  revalidatePath(`/jobs/${jobId}`);
  return { ok: true };
}

export async function toggleRequirementAction(jobId: string, requirementId: string, kind: "must" | "nice") {
  const user = await requireUser();
  if (!uuidSchema.safeParse(requirementId).success || !["must", "nice"].includes(kind)) return;
  await updateRequirementKind(user.id, requirementId, kind);
  revalidatePath(`/jobs/${jobId}`);
}

export async function deleteRequirementAction(jobId: string, requirementId: string) {
  const user = await requireUser();
  if (!uuidSchema.safeParse(requirementId).success) return;
  await deleteRequirement(user.id, requirementId);
  revalidatePath(`/jobs/${jobId}`);
}

export async function runFitAnalysisAction(jobId: string): Promise<ActionState> {
  const user = await requireUser();
  if (!uuidSchema.safeParse(jobId).success) return { error: "Job not found." };
  const [job, bundle, career] = await Promise.all([getJob(user.id, jobId), getProfileBundle(user.id), getCareerProfile(user.id)]);
  if (!job) return { error: "Job not found." };
  if (!career.resume) return { error: "Add a resume first. Fit analysis compares the job against your resume and evidence." };

  let requirements = await listRequirements(user.id, jobId);
  if (requirements.length === 0 && job.description.trim()) {
    await replaceRequirements(user.id, jobId, extractRequirements(job.description));
    requirements = await listRequirements(user.id, jobId);
  }
  if (requirements.length === 0) return { error: "No requirements found. Add the key requirements below, then run the analysis." };

  const provider = await providerForUser(user.id);
  const input = buildFitInput(job, requirements, bundle.profile, bundle.targetRoles, career);
  try {
    await consumeAIQuota(user.id, PROMPT_VERSIONS.fit);
    // Validate the provider's draft even for the mock provider: the same pipeline for every source.
    const draft = fitDraftSchema.parse(await provider.analyzeFit(input));
    const result = finalizeFit(draft, input);
    if (detectInjectionSignals(job.description)) {
      result.warnings.push("This job description contains text that looks like instructions to an AI system. It was treated as data and ignored.");
    }
    await saveFitAnalysis(user.id, jobId, career.resume.id, result, { provider: provider.name, model: provider.model, prompt_version: PROMPT_VERSIONS.fit });
  } catch (error) {
    if (!(error instanceof AIError)) console.error(JSON.stringify({ event: "fit_analysis_failed", name: (error as Error).name }));
    return { error: userMessageForAIError(error) };
  }
  revalidatePath(`/jobs/${jobId}`);
  revalidatePath("/jobs");
  revalidatePath("/today");
  return { ok: true, message: "Analysis updated." };
}

export async function createApplicationAction(jobId: string) {
  const user = await requireUser();
  if (!uuidSchema.safeParse(jobId).success) return;
  const id = await createApplication(user.id, jobId, await todayForUser());
  if (!id) return;
  revalidatePath("/applications");
  revalidatePath(`/jobs/${jobId}`);
  redirect(`/applications/${id}`);
}
