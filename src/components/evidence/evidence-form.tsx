"use client";

import { useActionForm } from "@/components/ui/use-action-form";
import { Alert, Card } from "@/components/ui/display";
import { Field, Input, Select, Textarea } from "@/components/ui/form";
import { SubmitButton } from "@/components/ui/submit-button";
import type { EvidenceItem } from "@/lib/data/evidence";
import type { ActionState } from "@/lib/forms";

export function EvidenceForm({ action, initial }: { action: (s: ActionState, fd: FormData) => Promise<ActionState>; initial?: EvidenceItem }) {
  const { state, pending, formProps } = useActionForm(action);
  const err = state?.fieldErrors ?? {};
  return (
    <form {...formProps} className="space-y-4" noValidate>
      {state?.error && <Alert tone="danger">{state.error}</Alert>}
      <Card>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field id="title" label="Title" error={err.title} className="sm:col-span-2">
            <Input id="title" name="title" defaultValue={initial?.title} required aria-invalid={Boolean(err.title)} placeholder="e.g. Migrated payments services to Kubernetes" />
          </Field>
          <Field id="organization" label="Employer or project">
            <Input id="organization" name="organization" defaultValue={initial?.organization} />
          </Field>
          <Field id="metric" label="Quantified result" hint="Only a figure you can verify. Leave blank if there is none.">
            <Input id="metric" name="metric" defaultValue={initial?.metric} placeholder="e.g. 28% lower infrastructure cost" />
          </Field>
          <Field id="situation" label="Situation or problem" className="sm:col-span-2">
            <Textarea id="situation" name="situation" rows={3} defaultValue={initial?.situation} />
          </Field>
          <Field id="action" label="Action you took" className="sm:col-span-2">
            <Textarea id="action" name="action" rows={3} defaultValue={initial?.action} />
          </Field>
          <Field id="result" label="Result" className="sm:col-span-2">
            <Textarea id="result" name="result" rows={3} defaultValue={initial?.result} />
          </Field>
          <Field id="skills" label="Skills demonstrated" hint="Comma separated." className="sm:col-span-2">
            <Input id="skills" name="skills" defaultValue={initial?.skills.join(", ")} />
          </Field>
          <Field id="confidence" label="Confidence">
            <Select id="confidence" name="confidence" defaultValue={initial?.confidence ?? "medium"}>
              <option value="high">High — documented or easy to evidence</option>
              <option value="medium">Medium — accurate from memory</option>
              <option value="low">Low — details need checking</option>
            </Select>
          </Field>
          <Field id="verification_status" label="Verification" hint="Only verified evidence is used for STAR stories.">
            <Select id="verification_status" name="verification_status" defaultValue={initial?.verification_status ?? "verified"}>
              <option value="verified">Verified — I confirm this is accurate</option>
              <option value="unverified">Unverified — needs review</option>
              <option value="rejected">Rejected — do not use</option>
            </Select>
          </Field>
          <Field id="notes" label="Notes" className="sm:col-span-2">
            <Textarea id="notes" name="notes" rows={2} defaultValue={initial?.notes} />
          </Field>
        </div>
      </Card>
      <SubmitButton pending={pending}>Save evidence</SubmitButton>
    </form>
  );
}
