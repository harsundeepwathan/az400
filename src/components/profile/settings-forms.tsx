"use client";

import { useActionForm } from "@/components/ui/use-action-form";
import { Alert } from "@/components/ui/display";
import { Checkbox, Field, Input } from "@/components/ui/form";
import { SubmitButton } from "@/components/ui/submit-button";
import type { ActionState } from "@/lib/forms";

type Action = (s: ActionState, fd: FormData) => Promise<ActionState>;

export function PreferencesForm({ action, initial }: { action: Action; initial: { weekly_application_goal: number; follow_up_after_days: number; ai_assistance_enabled: boolean } }) {
  const { state, pending, formProps } = useActionForm(action);
  return (
    <form {...formProps} className="space-y-4" noValidate>
      {state?.error && <Alert tone="danger">{state.error}</Alert>}
      <div className="grid gap-4 sm:grid-cols-2">
        <Field id="weekly_application_goal" label="Weekly application goal" error={state?.fieldErrors?.weekly_application_goal}>
          <Input id="weekly_application_goal" name="weekly_application_goal" type="number" min={0} max={100} defaultValue={initial.weekly_application_goal} />
        </Field>
        <Field id="follow_up_after_days" label="Follow up after (days)" hint="Used to schedule a follow-up when you mark an application as applied." error={state?.fieldErrors?.follow_up_after_days}>
          <Input id="follow_up_after_days" name="follow_up_after_days" type="number" min={1} max={60} defaultValue={initial.follow_up_after_days} />
        </Field>
      </div>
      <Checkbox
        name="ai_assistance_enabled"
        defaultChecked={initial.ai_assistance_enabled}
        label={<>Use the configured AI provider <span className="block text-xs text-muted">When off, analysis and drafts use the local deterministic engine and nothing is sent to an AI provider.</span></>}
      />
      <div className="flex items-center gap-3">
        <SubmitButton pending={pending}>Save preferences</SubmitButton>
        {state?.message && <p role="status" className="text-sm text-success">{state.message}</p>}
      </div>
    </form>
  );
}

export function DeleteAccountForm({ action, email }: { action: Action; email: string }) {
  const { state, pending, formProps } = useActionForm(action);
  return (
    <form {...formProps} className="space-y-3">
      {state?.error && <Alert tone="danger">{state.error}</Alert>}
      <Field id="confirm_email" label={<>Type <strong>{email}</strong> to confirm</>}>
        <Input id="confirm_email" name="confirm_email" autoComplete="off" />
      </Field>
      <SubmitButton pending={pending} variant="danger" pendingText="Deleting…">Permanently delete my account and data</SubmitButton>
    </form>
  );
}
