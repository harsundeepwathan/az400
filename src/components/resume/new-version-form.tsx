"use client";

import { useActionForm } from "@/components/ui/use-action-form";
import { Alert } from "@/components/ui/display";
import { Field, Input, Select } from "@/components/ui/form";
import { SubmitButton } from "@/components/ui/submit-button";
import type { ActionState } from "@/lib/forms";

export function NewVersionForm({
  action,
  resumes,
  jobs,
  defaultJobId,
}: {
  action: (s: ActionState, fd: FormData) => Promise<ActionState>;
  resumes: Array<{ id: string; title: string; is_primary: boolean }>;
  jobs: Array<{ id: string; label: string }>;
  defaultJobId?: string;
}) {
  const { state, pending, formProps } = useActionForm(action);
  return (
    <form {...formProps} className="grid gap-3 sm:grid-cols-[1fr_1fr_1fr_auto] sm:items-end">
      {state?.error && <Alert tone="danger" className="sm:col-span-4">{state.error}</Alert>}
      <Field id="v-name" label="Version name" error={state?.fieldErrors?.name}>
        <Input id="v-name" name="name" required placeholder="e.g. Platform roles — Q3" />
      </Field>
      <Field id="v-resume" label="Based on">
        <Select id="v-resume" name="resume_id" defaultValue={resumes.find((r) => r.is_primary)?.id}>
          {resumes.map((r) => <option key={r.id} value={r.id}>{r.title}</option>)}
        </Select>
      </Field>
      <Field id="v-job" label="Tailored for (optional)">
        <Select id="v-job" name="job_id" defaultValue={defaultJobId ?? ""}>
          <option value="">General</option>
          {jobs.map((j) => <option key={j.id} value={j.id}>{j.label}</option>)}
        </Select>
      </Field>
      <SubmitButton pending={pending} pendingText="Creating…">Create version</SubmitButton>
    </form>
  );
}
