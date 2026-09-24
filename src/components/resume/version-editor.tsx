"use client";

import { useActionForm } from "@/components/ui/use-action-form";
import { Alert, Card, CardHeader } from "@/components/ui/display";
import { Field, Input, Textarea } from "@/components/ui/form";
import { SubmitButton } from "@/components/ui/submit-button";
import type { VersionContent } from "@/lib/data/resumes";
import type { ActionState } from "@/lib/forms";

export function VersionEditor({
  action,
  version,
}: {
  action: (s: ActionState, fd: FormData) => Promise<ActionState>;
  version: { name: string; summary: string; notes: string; content: VersionContent };
}) {
  const { state, pending, formProps } = useActionForm(action);
  return (
    <form {...formProps} className="space-y-4">
      {state?.error && <Alert tone="danger">{state.error}</Alert>}
      <input type="hidden" name="content" value={JSON.stringify(version.content)} />
      <Card>
        <div className="grid gap-3">
          <Field id="name" label="Version name" error={state?.fieldErrors?.name}>
            <Input id="name" name="name" defaultValue={version.name} required />
          </Field>
          <Field id="summary" label="Professional summary">
            <Textarea id="summary" name="summary" rows={4} defaultValue={version.summary} />
          </Field>
        </div>
      </Card>
      <Card>
        <CardHeader title="Experience" description="Reorder, trim or reword bullets (one per line). Rewording should not add tools, numbers or outcomes that are not in your resume." />
        <div className="space-y-4">
          {version.content.employment.length === 0 && <p className="text-sm text-muted">The base resume has no roles.</p>}
          {version.content.employment.map((e, i) => (
            <Field key={e.employment_id} id={`bullets_${i}`} label={<>{e.heading} <span className="font-normal text-muted">· {e.dates}</span></>}>
              <Textarea id={`bullets_${i}`} name={`bullets_${i}`} rows={Math.min(10, Math.max(3, e.bullets.length + 1))} defaultValue={e.bullets.join("\n")} />
            </Field>
          ))}
        </div>
      </Card>
      <Card>
        <div className="grid gap-3">
          <Field id="skills" label="Skills" hint="Comma separated, in the order you want them shown.">
            <Textarea id="skills" name="skills" rows={2} defaultValue={version.content.skills.join(", ")} />
          </Field>
          <Field id="notes" label="Private notes" hint="Not printed.">
            <Textarea id="notes" name="notes" rows={2} defaultValue={version.notes} />
          </Field>
        </div>
      </Card>
      <div className="flex items-center gap-3">
        <SubmitButton pending={pending}>Save version</SubmitButton>
        {state?.message && <p role="status" className="text-sm text-success">{state.message}</p>}
      </div>
    </form>
  );
}
