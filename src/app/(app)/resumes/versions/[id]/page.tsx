import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Printer } from "lucide-react";
import { ActionButton } from "@/components/action-button";
import { VersionEditor } from "@/components/resume/version-editor";
import { ButtonLink } from "@/components/ui/button";
import { Alert, PageHeader } from "@/components/ui/display";
import { detectUnsupportedClaims } from "@/lib/claims";
import { getResume, getVersion } from "@/lib/data/resumes";
import { requireOnboardedUser } from "@/lib/session";
import { uuidSchema } from "@/lib/validation";
import { deleteVersionAction, updateVersionAction } from "../../actions";

export const metadata: Metadata = { title: "Resume version" };

export default async function VersionPage({ params }: { params: Promise<{ id: string }> }) {
  const { user } = await requireOnboardedUser();
  const { id } = await params;
  if (!uuidSchema.safeParse(id).success) notFound();
  const version = await getVersion(user.id, id);
  if (!version) notFound();
  const base = await getResume(user.id, version.resume_id);

  const baseText = base
    ? [base.summary, ...base.employment.flatMap((e) => [e.title, e.employer, ...e.responsibilities, ...e.achievements]), ...base.skills.map((s) => s.name), ...base.certifications.map((c) => c.name), ...base.projects.map((p) => `${p.name} ${p.description}`)].join("\n")
    : "";
  const versionText = [version.summary, ...version.content.employment.flatMap((e) => e.bullets), ...version.content.skills].join("\n");
  // Treat every term in the version as "job text" so anything absent from the base resume is flagged.
  const claims = base ? detectUnsupportedClaims(versionText, baseText, versionText) : [];

  return (
    <>
      <PageHeader
        title={version.name}
        description={<>Based on “{base?.title ?? "deleted resume"}”{version.job_label ? ` · tailored for ${version.job_label}` : ""}</>}
        actions={
          <>
            <ButtonLink href={`/print/resume-versions/${id}`} variant="secondary" target="_blank"><Printer className="h-4 w-4" aria-hidden /> Print / PDF</ButtonLink>
            <ActionButton action={deleteVersionAction.bind(null, id)} variant="danger" confirm="Delete this resume version? Applications that used it will keep their history but lose the link.">Delete</ActionButton>
          </>
        }
      />
      {claims.length > 0 && (
        <Alert tone="warning" title="Not found in your base resume" className="mb-4">
          <p>These terms or figures do not appear in the resume this version is based on. Make sure each one is true before you use this version.</p>
          <ul className="mt-1 list-disc pl-5">{claims.map((c) => <li key={c.claim}><strong>{c.claim}</strong></li>)}</ul>
        </Alert>
      )}
      <VersionEditor action={updateVersionAction.bind(null, id)} version={version} />
    </>
  );
}
