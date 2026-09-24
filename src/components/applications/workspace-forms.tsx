"use client";

import { useActionForm } from "@/components/ui/use-action-form";
import { useOptimistic, useTransition } from "react";
import { Alert } from "@/components/ui/display";
import { Checkbox, Field, Input, Select, Textarea } from "@/components/ui/form";
import { SubmitButton } from "@/components/ui/submit-button";
import {
  updateChecklistAction, updateSelectedEvidenceAction,
} from "@/app/(app)/applications/actions";
import type { Application, ChecklistItem } from "@/lib/data/applications";
import { CONTACT_ROLES, CONTACT_ROLE_LABELS, INTERVIEW_KINDS, INTERVIEW_KIND_LABELS, STAGES, STAGE_LABELS } from "@/lib/domain";
import type { ActionState } from "@/lib/forms";

type Action = (s: ActionState, fd: FormData) => Promise<ActionState>;

function Result({ state }: { state: ActionState }) {
  if (state?.error) return <p role="alert" className="text-sm text-danger">{state.error}</p>;
  if (state?.message) return <p role="status" className="text-sm text-success">{state.message}</p>;
  return null;
}

export function StageForm({ action, current }: { action: Action; current: string }) {
  const { state, pending, formProps } = useActionForm(action);
  return (
    <form {...formProps} className="flex flex-wrap items-end gap-2">
      <Field id="stage" label="Move to stage">
        <Select id="stage" name="stage" defaultValue={current} className="w-48">
          {STAGES.map((s) => <option key={s} value={s}>{STAGE_LABELS[s]}</option>)}
        </Select>
      </Field>
      <Field id="stage-note" label="Note (optional)">
        <Input id="stage-note" name="note" className="w-56" placeholder="e.g. Recruiter replied by email" />
      </Field>
      <SubmitButton pending={pending} variant="secondary" pendingText="Updating…">Update stage</SubmitButton>
      <Result state={state} />
    </form>
  );
}

export function DetailsForm({ action, app, versions }: { action: Action; app: Application; versions: Array<{ id: string; name: string }> }) {
  const { state, pending, formProps } = useActionForm(action);
  const err = state?.fieldErrors ?? {};
  return (
    <form {...formProps} className="grid gap-3 sm:grid-cols-2" noValidate>
      <Field id="resume_version_id" label="Resume version used" className="sm:col-span-2">
        <Select id="resume_version_id" name="resume_version_id" defaultValue={app.resume_version_id ?? ""}>
          <option value="">Not recorded</option>
          {versions.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
        </Select>
      </Field>
      <Field id="applied_on" label="Application date" error={err.applied_on}><Input id="applied_on" name="applied_on" type="date" defaultValue={app.applied_on ?? ""} /></Field>
      <Field id="follow_up_on" label="Follow-up date" error={err.follow_up_on}><Input id="follow_up_on" name="follow_up_on" type="date" defaultValue={app.follow_up_on ?? ""} /></Field>
      <Field id="next_action" label="Next action"><Input id="next_action" name="next_action" defaultValue={app.next_action} placeholder="e.g. Send portfolio link" /></Field>
      <Field id="next_action_on" label="Next action date" error={err.next_action_on}><Input id="next_action_on" name="next_action_on" type="date" defaultValue={app.next_action_on ?? ""} /></Field>
      <Field id="salary_expectation" label="Salary discussed"><Input id="salary_expectation" name="salary_expectation" defaultValue={app.salary_expectation} /></Field>
      <Field id="offer_deadline" label="Offer deadline" error={err.offer_deadline}><Input id="offer_deadline" name="offer_deadline" type="date" defaultValue={app.offer_deadline ?? ""} /></Field>
      <Field id="offer_details" label="Offer details" className="sm:col-span-2"><Textarea id="offer_details" name="offer_details" rows={2} defaultValue={app.offer_details} /></Field>
      <Field id="rejection_reason" label="Rejection reason" hint="Short and consistent wording makes analytics more useful." className="sm:col-span-2">
        <Input id="rejection_reason" name="rejection_reason" defaultValue={app.rejection_reason} placeholder="e.g. Not enough Kubernetes experience" />
      </Field>
      <Field id="notes" label="Notes" className="sm:col-span-2"><Textarea id="notes" name="notes" rows={4} defaultValue={app.notes} /></Field>
      <div className="flex items-center gap-3 sm:col-span-2">
        <SubmitButton pending={pending}>Save details</SubmitButton>
        <Result state={state} />
      </div>
    </form>
  );
}

export function ChecklistEditor({ id, items }: { id: string; items: ChecklistItem[] }) {
  const [optimistic, setOptimistic] = useOptimistic(items);
  const [, start] = useTransition();
  if (optimistic.length === 0) return <p className="text-sm text-muted">No checklist items.</p>;
  return (
    <ul className="space-y-2">
      {optimistic.map((item, i) => (
        <li key={item.label}>
          <Checkbox
            checked={item.done}
            onChange={(e) => {
              const next = optimistic.map((x, j) => (j === i ? { ...x, done: e.target.checked } : x));
              start(async () => {
                setOptimistic(next);
                await updateChecklistAction(id, next);
              });
            }}
            label={<span className={item.done ? "text-muted line-through" : ""}>{item.label}</span>}
          />
        </li>
      ))}
    </ul>
  );
}

export function EvidencePicker({ id, evidence, selected }: { id: string; evidence: Array<{ id: string; title: string; verified: boolean }>; selected: string[] }) {
  const [optimistic, setOptimistic] = useOptimistic(selected);
  const [, start] = useTransition();
  if (evidence.length === 0) return <p className="text-sm text-muted">Your evidence vault is empty.</p>;
  return (
    <ul className="space-y-2">
      {evidence.map((e) => (
        <li key={e.id}>
          <Checkbox
            checked={optimistic.includes(e.id)}
            onChange={(ev) => {
              const next = ev.target.checked ? [...optimistic, e.id] : optimistic.filter((x) => x !== e.id);
              start(async () => {
                setOptimistic(next);
                await updateSelectedEvidenceAction(id, next);
              });
            }}
            label={<>{e.title}{!e.verified && <span className="ml-1 text-xs text-warning">(unverified)</span>}</>}
          />
        </li>
      ))}
    </ul>
  );
}

export function MaterialsEditor({ action, content }: { action: Action; content: { summary: string; cover_letter: string; outreach_message: string } }) {
  const { state, pending, formProps } = useActionForm(action);
  return (
    <form {...formProps} className="space-y-4">
      <Field id="m-summary" label="Tailored professional summary"><Textarea id="m-summary" name="summary" rows={4} defaultValue={content.summary} /></Field>
      <Field id="m-cover" label="Cover letter draft"><Textarea id="m-cover" name="cover_letter" rows={14} defaultValue={content.cover_letter} /></Field>
      <Field id="m-outreach" label="Recruiter outreach message"><Textarea id="m-outreach" name="outreach_message" rows={4} defaultValue={content.outreach_message} /></Field>
      <div className="flex items-center gap-3">
        <SubmitButton pending={pending} variant="secondary">Save my edits</SubmitButton>
        <Result state={state} />
      </div>
    </form>
  );
}

export function ContactForm({ action }: { action: Action }) {
  const { state, pending, formProps } = useActionForm(action, { resetOnSuccess: true });
  const err = state?.fieldErrors ?? {};
  return (
    <form {...formProps} className="grid gap-2 sm:grid-cols-2" noValidate>
      {state?.error && <Alert tone="danger" className="sm:col-span-2">{state.error}</Alert>}
      <Field id="c-name" label="Name" error={err.name}><Input id="c-name" name="name" required /></Field>
      <Field id="c-role" label="Role">
        <Select id="c-role" name="role">{CONTACT_ROLES.map((r) => <option key={r} value={r}>{CONTACT_ROLE_LABELS[r]}</option>)}</Select>
      </Field>
      <Field id="c-email" label="Email" error={err.email}><Input id="c-email" name="email" type="email" /></Field>
      <Field id="c-phone" label="Phone"><Input id="c-phone" name="phone" /></Field>
      <Field id="c-url" label="Profile link" error={err.profile_url} className="sm:col-span-2"><Input id="c-url" name="profile_url" type="url" placeholder="https://…" /></Field>
      <input type="hidden" name="notes" value="" />
      <div className="flex items-center gap-3 sm:col-span-2">
        <SubmitButton pending={pending} variant="secondary" pendingText="Adding…">Add contact</SubmitButton>
        <Result state={state} />
      </div>
    </form>
  );
}

export function InterviewForm({ action, defaultDate }: { action: Action; defaultDate: string }) {
  const { state, pending, formProps } = useActionForm(action, { resetOnSuccess: true });
  const err = state?.fieldErrors ?? {};
  return (
    <form {...formProps} className="grid gap-2 sm:grid-cols-2" noValidate>
      {state?.error && <Alert tone="danger" className="sm:col-span-2">{state.error}</Alert>}
      <Field id="i-date" label="Date" error={err.date}><Input id="i-date" name="date" type="date" defaultValue={defaultDate} required /></Field>
      <Field id="i-time" label="Time" error={err.time}><Input id="i-time" name="time" type="time" defaultValue="10:00" required /></Field>
      <Field id="i-kind" label="Type">
        <Select id="i-kind" name="kind">{INTERVIEW_KINDS.map((k) => <option key={k} value={k}>{INTERVIEW_KIND_LABELS[k]}</option>)}</Select>
      </Field>
      <Field id="i-with" label="Interviewers"><Input id="i-with" name="interviewers" /></Field>
      <Field id="i-loc" label="Location or link" className="sm:col-span-2"><Input id="i-loc" name="location" /></Field>
      <input type="hidden" name="notes" value="" />
      <div className="flex items-center gap-3 sm:col-span-2">
        <SubmitButton pending={pending} variant="secondary" pendingText="Scheduling…">Schedule interview</SubmitButton>
        <Result state={state} />
      </div>
    </form>
  );
}

export function TaskForm({ action, applicationId, defaultDate }: { action: Action; applicationId?: string; defaultDate: string }) {
  const { state, pending, formProps } = useActionForm(action, { resetOnSuccess: true });
  const err = state?.fieldErrors ?? {};
  return (
    <form {...formProps} className="flex flex-wrap items-end gap-2" noValidate>
      {applicationId && <input type="hidden" name="application_id" value={applicationId} />}
      <Field id="t-title" label="Reminder" error={err.title} className="min-w-48 flex-1"><Input id="t-title" name="title" placeholder="e.g. Chase references" /></Field>
      <Field id="t-due" label="Due" error={err.due_on}><Input id="t-due" name="due_on" type="date" defaultValue={defaultDate} /></Field>
      <SubmitButton pending={pending} variant="secondary" pendingText="Adding…">Add reminder</SubmitButton>
      <Result state={state} />
    </form>
  );
}

export function InterviewNotesForm({ action, notes, reflection }: { action: Action; notes: string; reflection: string }) {
  const { state, pending, formProps } = useActionForm(action);
  return (
    <form {...formProps} className="space-y-3">
      <Field id="notes" label="Interview notes" hint="Who you spoke to, what they asked, what you learned."><Textarea id="notes" name="notes" rows={5} defaultValue={notes} /></Field>
      <Field id="reflection" label="Post-interview reflection" hint="What went well, what to improve, and any new evidence worth adding to your vault.">
        <Textarea id="reflection" name="reflection" rows={4} defaultValue={reflection} />
      </Field>
      <div className="flex items-center gap-3">
        <SubmitButton pending={pending} variant="secondary">Save notes</SubmitButton>
        <Result state={state} />
      </div>
    </form>
  );
}
