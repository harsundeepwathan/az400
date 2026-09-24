"use client";

import { ResumeEditor } from "./resume-editor";
import type { ResumeDraft } from "@/lib/resume/schema";
import { updateResumeAction } from "@/app/(app)/resumes/actions";

export function ResumeEditClient({ id, initial }: { id: string; initial: ResumeDraft }) {
  return <ResumeEditor initial={initial} onSave={(draft) => updateResumeAction(id, JSON.stringify(draft))} />;
}
