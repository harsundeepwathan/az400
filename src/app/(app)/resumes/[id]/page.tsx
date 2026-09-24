import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { ActionButton } from "@/components/action-button";
import { ResumeEditClient } from "@/components/resume/resume-edit-client";
import { ButtonLink } from "@/components/ui/button";
import { Alert, Badge, PageHeader } from "@/components/ui/display";
import { getResume } from "@/lib/data/resumes";
import { requireOnboardedUser } from "@/lib/session";
import { uuidSchema } from "@/lib/validation";
import { deleteResumeAction, importEvidenceAction, setPrimaryResumeAction } from "../actions";

export const metadata: Metadata = { title: "Edit resume" };

export default async function ResumePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ saved?: string }> }) {
  const { user } = await requireOnboardedUser();
  const { id } = await params;
  if (!uuidSchema.safeParse(id).success) notFound();
  const resume = await getResume(user.id, id);
  if (!resume) notFound();
  const { saved } = await searchParams;
  const { id: _id, is_primary, source_type, original_filename, storage_path: _s, parse_status: _p, parse_warnings: _w, raw_text: _r, ...draft } = resume;

  return (
    <>
      <PageHeader
        title={resume.title}
        description={
          <>
            {source_type === "upload" ? `Uploaded from ${original_filename}` : "Entered as text"} ·{" "}
            {is_primary ? "Primary resume, used for fit analysis" : "Not the primary resume"}
          </>
        }
        actions={
          <>
            {!is_primary && <ActionButton action={setPrimaryResumeAction.bind(null, id)}>Make primary</ActionButton>}
            <ActionButton action={importEvidenceAction} pendingText="Importing…">Import achievements as evidence</ActionButton>
            <ActionButton action={deleteResumeAction.bind(null, id)} variant="danger" confirm="Delete this resume and its uploaded file? Resume versions based on it will also be deleted.">
              Delete
            </ActionButton>
          </>
        }
      />
      {saved && (
        <Alert tone="success" className="mb-4" title="Resume saved">
          Next: import your achievements into the Evidence vault, then save a job to analyse.
          <div className="mt-2 flex gap-2">
            <ButtonLink href="/evidence" size="sm" variant="secondary">Open evidence vault</ButtonLink>
            <ButtonLink href="/jobs/new" size="sm">Save a job</ButtonLink>
          </div>
        </Alert>
      )}
      {is_primary && <Badge tone="accent" className="mb-4">Primary</Badge>}
      <ResumeEditClient id={id} initial={{ ...draft, employment: draft.employment }} />
    </>
  );
}
