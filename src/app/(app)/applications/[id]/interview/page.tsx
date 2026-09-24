import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ActionButton } from "@/components/action-button";
import { InterviewNotesForm } from "@/components/applications/workspace-forms";
import { ProviderNotice } from "@/components/badges";
import { ButtonLink } from "@/components/ui/button";
import { Alert, Card, CardHeader, EmptyState, PageHeader } from "@/components/ui/display";
import type { PrepDraft } from "@/lib/ai/schemas";
import { getApplication, getLatestDocument, listInterviews } from "@/lib/data/applications";
import { listEvidence } from "@/lib/data/evidence";
import { INTERVIEW_KIND_LABELS } from "@/lib/domain";
import { userTimeZone } from "@/lib/server-date";
import { requireOnboardedUser } from "@/lib/session";
import { uuidSchema } from "@/lib/validation";
import { generatePrepAction, updateInterviewNotesAction } from "../../actions";

export const metadata: Metadata = { title: "Interview preparation" };

function List({ items }: { items: string[] }) {
  return items.length === 0 ? <p className="text-sm text-muted">Nothing here yet.</p> : <ul className="list-disc space-y-1.5 pl-5 text-sm">{items.map((q) => <li key={q}>{q}</li>)}</ul>;
}

export default async function InterviewPrepPage({ params }: { params: Promise<{ id: string }> }) {
  const { user } = await requireOnboardedUser();
  const { id } = await params;
  if (!uuidSchema.safeParse(id).success) notFound();
  const app = await getApplication(user.id, id);
  if (!app) notFound();
  const [interviews, doc, evidence, tz] = await Promise.all([
    listInterviews(user.id, id),
    getLatestDocument<PrepDraft>(user.id, id, "interview_prep"),
    listEvidence(user.id),
    userTimeZone(),
  ]);
  const evidenceTitles = new Map(evidence.map((e) => [e.id, e.title]));
  const prep = doc?.content;
  const warnings = (doc?.warnings as string[] | null) ?? [];

  return (
    <>
      <PageHeader
        title={`Interview prep: ${app.company}`}
        description={<>{app.job_title} · <Link href={`/applications/${id}`} className="text-accent hover:underline">Back to workspace</Link></>}
        actions={<ActionButton action={generatePrepAction.bind(null, id)} variant={prep ? "secondary" : "primary"} size="md" pendingText="Preparing…">{prep ? "Regenerate prep" : "Generate prep pack"}</ActionButton>}
      />
      <Alert tone="info" className="mb-4">
        Questions are based only on the job description and your own profile. JobPilot has no inside knowledge of {app.company}&apos;s interview process.
      </Alert>

      {prep ? (
        <div className="space-y-4">
          <div className="flex items-center gap-2 text-xs text-muted">
            <ProviderNotice provider={doc!.provider} />
            <span>Generated {new Date(doc!.created_at).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" })}</span>
          </div>
          {warnings.map((w) => <Alert key={w} tone="warning">{w}</Alert>)}
          <div className="grid gap-4 lg:grid-cols-2">
            <Card>
              <CardHeader title="Likely technical questions" as="h2" />
              {prep.technical_questions.length === 0 ? <p className="text-sm text-muted">No must-have requirements recorded.</p> : (
                <ul className="space-y-2 text-sm">
                  {prep.technical_questions.map((q) => <li key={q.question}>{q.question}<span className="block text-xs text-muted">Requirement: {q.requirement}</span></li>)}
                </ul>
              )}
            </Card>
            <Card><CardHeader title="Likely behavioural questions" as="h2" /><List items={prep.behavioural_questions} /></Card>
            <Card><CardHeader title="Company-specific questions" description="From the job description you saved." as="h2" /><List items={prep.company_questions} /></Card>
            <Card><CardHeader title="Questions to ask the interviewer" as="h2" /><List items={prep.questions_to_ask} /></Card>
          </div>
          <Card>
            <CardHeader title="STAR stories from verified evidence" description="Facts are copied from your evidence vault unchanged." as="h2" />
            {prep.star_stories.length === 0 ? (
              <p className="text-sm text-muted">No verified evidence yet. <Link href="/evidence" className="text-accent hover:underline">Verify items in your vault</Link> to get STAR suggestions.</p>
            ) : (
              <ul className="grid gap-3 md:grid-cols-2">
                {prep.star_stories.map((s) => (
                  <li key={s.evidence_id} className="rounded-md border border-line p-3 text-sm">
                    <Link href={`/evidence/${s.evidence_id}`} className="font-medium text-accent hover:underline">{evidenceTitles.get(s.evidence_id) ?? "Evidence item"}</Link>
                    <p className="text-xs text-muted">{s.prompt}</p>
                    <dl className="mt-2 space-y-1">
                      <div><dt className="inline font-medium">Situation: </dt><dd className="inline">{s.situation || <em className="text-muted">add in your vault</em>}</dd></div>
                      <div><dt className="inline font-medium">Action: </dt><dd className="inline">{s.action || <em className="text-muted">add in your vault</em>}</dd></div>
                      <div><dt className="inline font-medium">Result: </dt><dd className="inline">{s.result || <em className="text-muted">add in your vault</em>}</dd></div>
                    </dl>
                  </li>
                ))}
              </ul>
            )}
          </Card>
          <Card>
            <CardHeader title="Risk areas to prepare for" as="h2" />
            {prep.risk_areas.length === 0 ? <p className="text-sm text-muted">No gaps identified in the fit analysis.</p> : (
              <ul className="space-y-2 text-sm">{prep.risk_areas.map((r) => <li key={r.area}><strong>{r.area}</strong><span className="block text-muted">{r.preparation}</span></li>)}</ul>
            )}
          </Card>
        </div>
      ) : (
        <EmptyState title="No preparation pack yet" description="Generate likely questions, STAR stories linked to your verified evidence, and the risk areas to prepare for." />
      )}

      <section aria-labelledby="notes-h" className="mt-8">
        <h2 id="notes-h" className="mb-3 text-lg font-semibold">Interview notes and reflection</h2>
        {interviews.length === 0 ? (
          <Card>
            <p className="text-sm text-muted">No interviews scheduled yet.</p>
            <ButtonLink href={`/applications/${id}`} size="sm" variant="secondary" className="mt-3">Schedule from the workspace</ButtonLink>
          </Card>
        ) : (
          <div className="space-y-4">
            {interviews.map((i) => (
              <Card key={i.id}>
                <CardHeader
                  as="h3"
                  title={`${INTERVIEW_KIND_LABELS[i.kind as keyof typeof INTERVIEW_KIND_LABELS]} · ${new Date(i.scheduled_at).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short", timeZone: tz })}`}
                  description={[i.interviewers, i.location].filter(Boolean).join(" · ") || undefined}
                />
                <InterviewNotesForm action={updateInterviewNotesAction.bind(null, id, i.id)} notes={i.notes} reflection={i.reflection} />
              </Card>
            ))}
          </div>
        )}
      </section>
    </>
  );
}
