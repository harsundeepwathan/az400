import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ActionButton } from "@/components/action-button";
import {
  ChecklistEditor, ContactForm, DetailsForm, EvidencePicker, InterviewForm, MaterialsEditor, StageForm, TaskForm,
} from "@/components/applications/workspace-forms";
import { FitScore, ProviderNotice, RecommendationBadge, StageBadge } from "@/components/badges";
import { ButtonLink } from "@/components/ui/button";
import { Alert, Badge, Card, CardHeader } from "@/components/ui/display";
import type { MaterialsWarnings, Materials } from "@/lib/ai/postprocess";
import {
  getApplication, getLatestDocument, listContacts, listEvents, listInterviews,
} from "@/lib/data/applications";
import { listEvidence } from "@/lib/data/evidence";
import { getJob, getLatestFit } from "@/lib/data/jobs";
import { listVersions } from "@/lib/data/resumes";
import { listTasks } from "@/lib/data/tasks";
import { addDays, formatDate, relativeDay } from "@/lib/dates";
import { CONTACT_ROLE_LABELS, INTERVIEW_KIND_LABELS, INTERVIEW_STAGES, STAGE_LABELS } from "@/lib/domain";
import { todayForUser, userTimeZone } from "@/lib/server-date";
import { requireOnboardedUser } from "@/lib/session";
import { uuidSchema } from "@/lib/validation";
import { CompleteTaskButton } from "../../reminders/task-buttons";
import { createTaskAction } from "../../reminders/actions";
import {
  addContactAction, changeStageFormAction, deleteApplicationAction, deleteContactAction, deleteInterviewAction, generateMaterialsAction,
  saveMaterialsEditsAction, scheduleInterviewAction, updateDetailsAction,
} from "../actions";

export const metadata: Metadata = { title: "Application workspace" };

export default async function ApplicationPage({ params }: { params: Promise<{ id: string }> }) {
  const { user } = await requireOnboardedUser();
  const { id } = await params;
  if (!uuidSchema.safeParse(id).success) notFound();
  const app = await getApplication(user.id, id);
  if (!app) notFound();
  const [job, fit, evidence, versions, events, contacts, interviews, doc, tasks, today, tz] = await Promise.all([
    getJob(user.id, app.job_id),
    getLatestFit(user.id, app.job_id),
    listEvidence(user.id),
    listVersions(user.id),
    listEvents(user.id, id),
    listContacts(user.id, id),
    listInterviews(user.id, id),
    getLatestDocument<Materials & { edited_by_user?: boolean }>(user.id, id, "application_materials"),
    listTasks(user.id),
    todayForUser(),
    userTimeZone(),
  ]);
  if (!job) notFound();
  const appTasks = tasks.filter((t) => t.application_id === id);
  const warnings = (doc?.warnings as { claims?: MaterialsWarnings; notes?: string[] } | null) ?? {};
  const usable = evidence.filter((e) => e.verification_status !== "rejected");
  const selectedEvidence = usable.filter((e) => app.selected_evidence_ids.includes(e.id));

  return (
    <>
      <header className="mb-6">
        <p className="text-sm text-muted"><Link href="/applications" className="hover:underline">Applications</Link> / {job.company}</p>
        <div className="mt-1 flex flex-wrap items-center gap-3">
          <h1 className="text-2xl font-semibold">{job.title}</h1>
          <StageBadge stage={app.stage} />
        </div>
        <p className="mt-1 text-sm text-muted">
          {job.company}{job.location ? ` · ${job.location}` : ""} · <Link href={`/jobs/${job.id}`} className="text-accent hover:underline">Job details and fit analysis</Link>
        </p>
      </header>

      <Card className="mb-4">
        <div className="flex flex-wrap items-end justify-between gap-4">
          <StageForm action={changeStageFormAction.bind(null, id)} current={app.stage} />
          <div className="flex flex-wrap gap-2">
            {(INTERVIEW_STAGES.includes(app.stage) || interviews.length > 0) && <ButtonLink href={`/applications/${id}/interview`} variant="secondary">Interview prep</ButtonLink>}
            <ActionButton action={deleteApplicationAction.bind(null, id)} variant="danger" size="md" confirm="Stop tracking this application? Its history, contacts and interviews will be deleted. The saved job stays.">Delete</ActionButton>
          </div>
        </div>
      </Card>

      <div className="grid gap-4 lg:grid-cols-[3fr_2fr]">
        <div className="space-y-4">
          <Card>
            <CardHeader
              title="Application materials"
              description="Drafted only from your resume, evidence and verified matches. Suggestions never add experience you have not recorded."
              action={
                <ActionButton action={generateMaterialsAction.bind(null, id)} variant={doc ? "secondary" : "primary"} pendingText="Drafting…" confirm={doc?.content.edited_by_user ? "Regenerating replaces your edited drafts. Continue?" : undefined}>
                  {doc ? "Regenerate drafts" : "Draft materials"}
                </ActionButton>
              }
            />
            {!fit && <Alert tone="info">Run the <Link href={`/jobs/${job.id}`} className="font-medium underline">fit analysis</Link> first; drafts build on its verified matches.</Alert>}
            {doc ? (
              <div className="space-y-5">
                <div className="flex flex-wrap items-center gap-2 text-xs text-muted">
                  <ProviderNotice provider={doc.provider} />
                  <span>Generated {new Date(doc.created_at).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" })}</span>
                  {doc.content.edited_by_user && <Badge>Edited by you</Badge>}
                </div>
                {(warnings.claims?.length ?? 0) > 0 && (
                  <Alert tone="warning" title="Check before using: possibly unsupported claims">
                    <ul className="list-disc pl-5">
                      {warnings.claims!.map((w) => (
                        <li key={w.section}><strong>{w.section}:</strong> {w.claims.map((c) => `“${c.claim}”`).join(", ")} — not found in your profile.</li>
                      ))}
                    </ul>
                  </Alert>
                )}
                {(warnings.notes ?? []).map((n) => <Alert key={n} tone="info">{n}</Alert>)}

                <section aria-labelledby="bullets-h">
                  <h3 id="bullets-h" className="text-sm font-semibold">Recommended resume bullet changes</h3>
                  {doc.content.bullet_suggestions.length === 0 ? (
                    <p className="mt-1 text-sm text-muted">No bullet changes suggested.</p>
                  ) : (
                    <ul className="mt-2 space-y-3">
                      {doc.content.bullet_suggestions.map((s) => (
                        <li key={s.bullet_id} className="rounded-md border border-line p-3 text-sm">
                          <p className="text-xs text-muted">{s.role}</p>
                          {s.suggested.trim() === s.original.trim() ? (
                            <p className="mt-1">{s.original}</p>
                          ) : (
                            <>
                              <p className="mt-1 text-muted line-through decoration-muted/50">{s.original}</p>
                              <p className="mt-1">{s.suggested}</p>
                            </>
                          )}
                          <p className="mt-1 text-xs text-muted">{s.rationale}</p>
                          {s.unsupported.length > 0 && (
                            <p className="mt-1 text-xs font-medium text-warning">Not in the original bullet: {s.unsupported.map((c) => c.claim).join(", ")}</p>
                          )}
                        </li>
                      ))}
                    </ul>
                  )}
                </section>

                <section aria-labelledby="kw-h">
                  <h3 id="kw-h" className="text-sm font-semibold">Keywords you can use truthfully</h3>
                  <p className="text-xs text-muted">Terms from the job description that your profile supports.</p>
                  <div className="mt-2 flex flex-wrap gap-1.5">
                    {doc.content.keywords.length === 0 ? <span className="text-sm text-muted">None found.</span> : doc.content.keywords.map((k) => <Badge key={k}>{k}</Badge>)}
                  </div>
                </section>

                <MaterialsEditor action={saveMaterialsEditsAction.bind(null, id)} content={doc.content} />
              </div>
            ) : (
              fit && <p className="text-sm text-muted">No drafts yet.</p>
            )}
          </Card>

          <Card>
            <CardHeader title="Tracking details" />
            <DetailsForm action={updateDetailsAction.bind(null, id)} app={app} versions={versions.map((v) => ({ id: v.id, name: v.name }))} />
            <p className="mt-3 text-xs text-muted">
              Need a tailored version? <Link href={`/resumes?job=${job.id}`} className="text-accent hover:underline">Create one from Resumes</Link>.
            </p>
          </Card>

          <Card>
            <CardHeader title="Interviews" />
            {interviews.length > 0 && (
              <ul className="mb-4 divide-y divide-line">
                {interviews.map((i) => (
                  <li key={i.id} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
                    <span>
                      <strong>{INTERVIEW_KIND_LABELS[i.kind as keyof typeof INTERVIEW_KIND_LABELS]}</strong> ·{" "}
                      {new Date(i.scheduled_at).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short", timeZone: tz })}
                      {i.interviewers ? ` · ${i.interviewers}` : ""}
                    </span>
                    <span className="flex gap-2">
                      <ButtonLink href={`/applications/${id}/interview`} size="sm" variant="secondary">Prepare</ButtonLink>
                      <ActionButton action={deleteInterviewAction.bind(null, id, i.id)} variant="ghost" confirm="Remove this interview?">Remove</ActionButton>
                    </span>
                  </li>
                ))}
              </ul>
            )}
            <InterviewForm action={scheduleInterviewAction.bind(null, id)} defaultDate={addDays(today, 3)} />
          </Card>
        </div>

        <div className="space-y-4">
          <Card>
            <CardHeader title="Fit" />
            {fit ? (
              <div className="flex items-center gap-3">
                <FitScore score={fit.score} size="lg" />
                <div>
                  <RecommendationBadge recommendation={fit.recommendation} />
                  <p className="mt-1 text-xs text-muted">{fit.coverage.must.strong}/{fit.coverage.must.total} must-haves strongly supported</p>
                </div>
              </div>
            ) : (
              <p className="text-sm text-muted">Not analysed yet.</p>
            )}
          </Card>

          <Card>
            <CardHeader title="Checklist" />
            <ChecklistEditor id={id} items={app.checklist} />
          </Card>

          <Card>
            <CardHeader title="Evidence to use" description={`${selectedEvidence.length} selected. Selected items are prioritised in interview prep.`} />
            <EvidencePicker id={id} evidence={usable.map((e) => ({ id: e.id, title: e.title, verified: e.verification_status === "verified" }))} selected={app.selected_evidence_ids} />
          </Card>

          <Card>
            <CardHeader title="Reminders" />
            {appTasks.length > 0 && (
              <ul className="mb-3 divide-y divide-line">
                {appTasks.map((t) => (
                  <li key={t.id} className="flex items-center justify-between gap-2 py-2 text-sm">
                    <span>
                      {t.title}
                      <span className={`block text-xs ${t.due_on < today ? "text-danger" : "text-muted"}`}>Due {relativeDay(t.due_on, today)}</span>
                    </span>
                    <CompleteTaskButton id={t.id} />
                  </li>
                ))}
              </ul>
            )}
            <TaskForm action={createTaskAction} applicationId={id} defaultDate={addDays(today, 2)} />
          </Card>

          <Card>
            <CardHeader title="Contacts" />
            {contacts.length > 0 && (
              <ul className="mb-3 divide-y divide-line">
                {contacts.map((c) => (
                  <li key={c.id} className="flex items-start justify-between gap-2 py-2 text-sm">
                    <span>
                      <strong>{c.name}</strong> · {CONTACT_ROLE_LABELS[c.role as keyof typeof CONTACT_ROLE_LABELS]}
                      {c.email && <span className="block text-xs text-muted">{c.email}</span>}
                      {c.phone && <span className="block text-xs text-muted">{c.phone}</span>}
                    </span>
                    <ActionButton action={deleteContactAction.bind(null, id, c.id)} variant="ghost" confirm={`Remove ${c.name}?`}>Remove</ActionButton>
                  </li>
                ))}
              </ul>
            )}
            <ContactForm action={addContactAction.bind(null, id)} />
          </Card>

          <Card>
            <CardHeader title="Status history" />
            <ol className="space-y-2 text-sm">
              {events.map((e) => (
                <li key={e.id} className="border-l-2 border-line pl-3">
                  <p>{e.from_stage ? <>{STAGE_LABELS[e.from_stage]} → <strong>{STAGE_LABELS[e.to_stage]}</strong></> : <>Created in <strong>{STAGE_LABELS[e.to_stage]}</strong></>}</p>
                  <p className="text-xs text-muted">{new Date(e.occurred_at).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short", timeZone: tz })}{e.note ? ` · ${e.note}` : ""}</p>
                </li>
              ))}
            </ol>
          </Card>

          <Card>
            <details>
              <summary className="cursor-pointer text-sm font-semibold">Original job description</summary>
              <div className="mt-2 max-h-96 overflow-y-auto whitespace-pre-wrap text-sm">{job.description || "No description saved."}</div>
            </details>
            <p className="mt-2 text-xs text-muted">Applied {formatDate(app.applied_on)}</p>
          </Card>
        </div>
      </div>
    </>
  );
}
