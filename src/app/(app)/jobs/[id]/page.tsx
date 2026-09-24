import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ExternalLink } from "lucide-react";
import { ActionButton } from "@/components/action-button";
import { StageBadge } from "@/components/badges";
import { FitAnalysisView } from "@/components/jobs/fit-analysis";
import { RequirementsEditor } from "@/components/jobs/requirements-editor";
import { ButtonLink } from "@/components/ui/button";
import { Alert, Card, CardHeader, EmptyState, PageHeader } from "@/components/ui/display";
import { getProvider } from "@/lib/ai";
import { getJob, getLatestFit, listRequirements } from "@/lib/data/jobs";
import { listResumes } from "@/lib/data/resumes";
import { formatDate } from "@/lib/dates";
import { requireOnboardedUser } from "@/lib/session";
import { uuidSchema } from "@/lib/validation";
import {
  addRequirementAction, createApplicationAction, deleteJobAction, deleteRequirementAction, reextractRequirementsAction, runFitAnalysisAction,
  toggleRequirementAction,
} from "../actions";

export const metadata: Metadata = { title: "Job" };

function money(n: number | null, currency: string) {
  return n === null ? null : `${currency} ${n.toLocaleString("en-US")}`;
}

export default async function JobPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ saved?: string }> }) {
  const { user } = await requireOnboardedUser();
  const { id } = await params;
  if (!uuidSchema.safeParse(id).success) notFound();
  const [job, fit, requirements, resumes] = await Promise.all([getJob(user.id, id), getLatestFit(user.id, id), listRequirements(user.id, id), listResumes(user.id)]);
  if (!job) notFound();
  const { saved } = await searchParams;
  const provider = getProvider();
  const salary = [money(job.salary_min, job.currency), money(job.salary_max, job.currency)].filter(Boolean).join(" – ");

  return (
    <>
      <PageHeader
        title={job.title}
        description={
          <>
            {job.company}
            {job.location ? ` · ${job.location}` : ""}
            {job.workplace_type !== "unknown" ? ` · ${job.workplace_type}` : ""}
            {salary ? ` · ${salary}` : ""}
          </>
        }
        actions={
          <>
            {job.application_id ? (
              <ButtonLink href={`/applications/${job.application_id}`}>Open application</ButtonLink>
            ) : (
              <ActionButton action={createApplicationAction.bind(null, id)} variant="primary" size="md" pendingText="Creating…">Start application</ActionButton>
            )}
            <ButtonLink href={`/jobs/${id}/edit`} variant="secondary">Edit</ButtonLink>
            <ActionButton action={deleteJobAction.bind(null, id)} variant="danger" size="md" confirm="Delete this job, its analyses and any application tracking for it?">Delete</ActionButton>
          </>
        }
      />
      {saved && <Alert tone="success" className="mb-4">Job saved. Review the extracted requirements, then run the fit analysis.</Alert>}
      {job.stage && (
        <p className="mb-4 text-sm">Application status: <StageBadge stage={job.stage} /></p>
      )}

      <section aria-labelledby="fit-h" className="mb-8">
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
          <h2 id="fit-h" className="text-lg font-semibold">Fit analysis</h2>
          {resumes.length > 0 && (
            <ActionButton action={runFitAnalysisAction.bind(null, id)} variant={fit ? "secondary" : "primary"} size="md" pendingText="Analysing…">
              {fit ? "Re-run analysis" : "Run fit analysis"}
            </ActionButton>
          )}
        </div>
        {resumes.length === 0 ? (
          <EmptyState title="Add a resume to analyse your fit" description="The analysis compares this job against your resume and evidence vault, citing each source." action={<ButtonLink href="/resumes/new">Add resume</ButtonLink>} />
        ) : fit ? (
          <FitAnalysisView fit={fit} />
        ) : (
          <Card>
            <p className="text-sm text-muted">
              Not analysed yet. The analysis runs with the {provider.name === "mock" ? "offline demo provider (deterministic, clearly labelled)" : "configured AI provider"} and checks every claim against your profile.
            </p>
          </Card>
        )}
      </section>

      <div className="grid gap-4 lg:grid-cols-[3fr_2fr]">
        <Card>
          <CardHeader
            title="Requirements"
            description="Used for the analysis. Toggle must-have or nice-to-have, remove noise, or add what was missed."
            action={<ActionButton action={reextractRequirementsAction.bind(null, id)} variant="ghost" pendingText="Extracting…" confirm="Replace the current requirements with a fresh extraction from the job description?">Re-extract</ActionButton>}
          />
          <RequirementsEditor
            requirements={requirements}
            addAction={addRequirementAction.bind(null, id)}
            toggleAction={toggleRequirementAction.bind(null, id)}
            deleteAction={deleteRequirementAction.bind(null, id)}
          />
        </Card>
        <Card>
          <CardHeader title="Details" />
          <dl className="space-y-2 text-sm">
            <div className="flex justify-between gap-3"><dt className="text-muted">Source</dt><dd>{job.source || "—"}</dd></div>
            <div className="flex justify-between gap-3"><dt className="text-muted">Discovered</dt><dd>{formatDate(job.discovered_on)}</dd></div>
            <div className="flex justify-between gap-3"><dt className="text-muted">Closes</dt><dd>{formatDate(job.closes_on)}</dd></div>
            <div className="flex justify-between gap-3"><dt className="text-muted">Contact</dt><dd className="text-right">{job.contact_name || "—"}{job.contact_email ? <><br />{job.contact_email}</> : null}</dd></div>
            {job.url && (
              <div className="flex justify-between gap-3">
                <dt className="text-muted">Link</dt>
                <dd><a href={job.url} target="_blank" rel="noopener noreferrer nofollow" className="inline-flex items-center gap-1 text-accent hover:underline">Open posting <ExternalLink className="h-3 w-3" aria-hidden /></a></dd>
              </div>
            )}
          </dl>
          {job.notes && <p className="mt-3 whitespace-pre-wrap border-t border-line pt-3 text-sm">{job.notes}</p>}
        </Card>
      </div>

      <Card className="mt-4">
        <details>
          <summary className="cursor-pointer font-semibold">Original job description</summary>
          <div className="mt-3 max-h-[32rem] overflow-y-auto whitespace-pre-wrap text-sm text-ink/90">{job.description || "No description saved."}</div>
        </details>
      </Card>
      <p className="mt-4 text-sm"><Link href="/jobs" className="text-accent hover:underline">← All jobs</Link></p>
    </>
  );
}
