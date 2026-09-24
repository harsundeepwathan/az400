"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { importEvidenceFromResume } from "@/lib/data/evidence";
import {
  createResume, createVersion, deleteResume, deleteVersion, setPrimaryResume, updateResume, updateVersion, type VersionContent,
} from "@/lib/data/resumes";
import { str, type ActionState } from "@/lib/forms";
import { extractResumeText } from "@/lib/resume/extract";
import { RESUME_TYPES } from "@/lib/resume/file";
import { parseResumeText } from "@/lib/resume/parse";
import { emptyDraft, resumeDraftSchema, type ParseResult, type ResumeDraft } from "@/lib/resume/schema";
import { deleteResumeFiles, storeResumeFile } from "@/lib/storage";
import { uuidSchema } from "@/lib/validation";

const MAX_PASTE = 60_000;

export type ParseResponse = { ok: true; result: ParseResult } | { ok: false; error: string };

/** Extracts and structures a resume for preview. Nothing is stored at this point. */
export async function parseResumeAction(fd: FormData): Promise<ParseResponse> {
  await requireUser();
  const mode = str(fd, "mode");
  const title = str(fd, "title") || "My resume";
  if (mode === "manual") return { ok: true, result: { status: "manual", draft: emptyDraft(title), warnings: [] } };
  if (mode === "paste") {
    const text = String(fd.get("text") ?? "");
    if (text.length > MAX_PASTE) return { ok: false, error: "The pasted text is too long (60,000 characters max)." };
    return { ok: true, result: parseResumeText(text, title) };
  }
  const file = fd.get("file");
  if (!(file instanceof File) || file.size === 0) return { ok: false, error: "Choose a PDF or DOCX file to upload." };
  const extraction = await extractResumeText(file.name, new Uint8Array(await file.arrayBuffer()));
  if (!extraction.ok) return { ok: false, error: extraction.error };
  return { ok: true, result: parseResumeText(extraction.text, title || file.name.replace(/\.[^.]+$/, "")) };
}

export type SaveResponse = { ok: boolean; error?: string; message?: string } | undefined;

function parseDraft(json: string): { ok: true; draft: ResumeDraft } | { ok: false; error: string } {
  let raw: unknown;
  try {
    raw = JSON.parse(json);
  } catch {
    return { ok: false, error: "Invalid resume data." };
  }
  const parsed = resumeDraftSchema.safeParse(raw);
  if (!parsed.success) {
    const first = parsed.error.issues[0];
    return { ok: false, error: `Please check “${first?.path.join(" › ")}”: ${first?.message}` };
  }
  return { ok: true, draft: parsed.data };
}

export async function createResumeAction(fd: FormData): Promise<SaveResponse> {
  const user = await requireUser();
  const draft = parseDraft(str(fd, "draft"));
  if (!draft.ok) return { ok: false, error: draft.error };
  const mode = str(fd, "mode");
  const status = z.enum(["parsed", "partial", "unreadable", "manual"]).catch("manual").parse(str(fd, "parse_status"));
  const warnings = z.array(z.string().max(500)).max(20).catch([]).parse(JSON.parse(str(fd, "parse_warnings") || "[]"));

  let meta = {
    source_type: "paste" as "upload" | "paste",
    original_filename: null as string | null,
    storage_path: null as string | null,
    mime_type: null as string | null,
    file_size: null as number | null,
    raw_text: "",
    parse_status: status,
    parse_warnings: warnings,
  };

  if (mode === "upload") {
    const file = fd.get("file");
    if (!(file instanceof File)) return { ok: false, error: "The uploaded file is missing. Please upload it again." };
    const bytes = new Uint8Array(await file.arrayBuffer());
    const extraction = await extractResumeText(file.name, bytes);
    if (!extraction.ok) return { ok: false, error: extraction.error };
    const storagePath = await storeResumeFile(user.id, extraction.kind, bytes);
    meta = {
      ...meta,
      source_type: "upload",
      original_filename: file.name.slice(0, 255),
      storage_path: storagePath,
      mime_type: RESUME_TYPES[extraction.kind],
      file_size: bytes.byteLength,
      raw_text: extraction.text.slice(0, 200_000),
    };
  } else {
    meta.raw_text = String(fd.get("text") ?? "").slice(0, MAX_PASTE);
  }

  const id = await createResume(user.id, draft.draft, meta);
  revalidatePath("/resumes");
  redirect(`/resumes/${id}?saved=1`);
}

export async function updateResumeAction(id: string, json: string): Promise<SaveResponse> {
  const user = await requireUser();
  if (!uuidSchema.safeParse(id).success) return { ok: false, error: "Resume not found." };
  const draft = parseDraft(json);
  if (!draft.ok) return { ok: false, error: draft.error };
  const updated = await updateResume(user.id, id, draft.draft);
  if (!updated) return { ok: false, error: "Resume not found." };
  revalidatePath("/resumes");
  revalidatePath(`/resumes/${id}`);
  return { ok: true, message: "Saved. Re-run fit analyses to use your changes." };
}

export async function setPrimaryResumeAction(id: string) {
  const user = await requireUser();
  if (!uuidSchema.safeParse(id).success) return;
  await setPrimaryResume(user.id, id);
  revalidatePath("/resumes");
}

export async function deleteResumeAction(id: string) {
  const user = await requireUser();
  if (!uuidSchema.safeParse(id).success) return;
  const deleted = await deleteResume(user.id, id);
  if (deleted?.storage_path) await deleteResumeFiles(user.id, [deleted.storage_path]);
  revalidatePath("/resumes");
  redirect("/resumes");
}

export async function importEvidenceAction(): Promise<ActionState> {
  const user = await requireUser();
  const created = await importEvidenceFromResume(user.id);
  revalidatePath("/evidence");
  return created === 0
    ? { ok: true, message: "No new achievements to import." }
    : { ok: true, message: `Imported ${created} achievement${created === 1 ? "" : "s"} as unverified evidence. Review them in the Evidence vault.` };
}

// ---------------------------------------------------------------------------
// Versions
// ---------------------------------------------------------------------------

export async function createVersionAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  const resumeId = str(fd, "resume_id");
  const name = str(fd, "name");
  const jobId = str(fd, "job_id") || null;
  if (!uuidSchema.safeParse(resumeId).success) return { error: "Choose a base resume." };
  if (!name || name.length > 200) return { fieldErrors: { name: "Name this version (max 200 characters)." } };
  if (jobId && !uuidSchema.safeParse(jobId).success) return { error: "Invalid job." };
  const id = await createVersion(user.id, resumeId, name, jobId);
  if (!id) return { error: "Resume not found." };
  revalidatePath("/resumes");
  redirect(`/resumes/versions/${id}`);
}

const versionContentSchema = z.object({
  employment: z
    .array(z.object({ employment_id: z.string().max(100), heading: z.string().max(500), dates: z.string().max(100), bullets: z.array(z.string().max(1000)).max(40) }))
    .max(40),
  skills: z.array(z.string().max(100)).max(200),
});

export async function updateVersionAction(id: string, _: ActionState, fd: FormData): Promise<ActionState> {
  const user = await requireUser();
  if (!uuidSchema.safeParse(id).success) return { error: "Version not found." };
  let content: VersionContent;
  try {
    const raw = JSON.parse(str(fd, "content"));
    const bulletsByIndex = raw.employment.map((_: unknown, i: number) =>
      String(fd.get(`bullets_${i}`) ?? "").split("\n").map((s) => s.trim()).filter(Boolean),
    );
    content = versionContentSchema.parse({
      employment: raw.employment.map((e: VersionContent["employment"][number], i: number) => ({ ...e, bullets: bulletsByIndex[i] })),
      skills: str(fd, "skills").split(/[,\n]/).map((s) => s.trim()).filter(Boolean),
    });
  } catch {
    return { error: "Could not read the version content." };
  }
  const name = str(fd, "name");
  if (!name) return { fieldErrors: { name: "Name this version." } };
  const saved = await updateVersion(user.id, id, { name, summary: str(fd, "summary").slice(0, 5000), notes: str(fd, "notes").slice(0, 5000), content });
  if (!saved) return { error: "Version not found." };
  revalidatePath(`/resumes/versions/${id}`);
  revalidatePath("/resumes");
  return { ok: true, message: "Version saved." };
}

export async function deleteVersionAction(id: string) {
  const user = await requireUser();
  if (!uuidSchema.safeParse(id).success) return;
  await deleteVersion(user.id, id);
  revalidatePath("/resumes");
  redirect("/resumes");
}

