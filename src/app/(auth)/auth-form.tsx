"use client";

import { useActionForm } from "@/components/ui/use-action-form";
import Link from "next/link";
import { Alert } from "@/components/ui/display";
import { Field, Input } from "@/components/ui/form";
import { SubmitButton } from "@/components/ui/submit-button";
import type { ActionState } from "@/lib/forms";

export function AuthForm({
  mode,
  action,
  next,
}: {
  mode: "sign-in" | "sign-up";
  action: (state: ActionState, fd: FormData) => Promise<ActionState>;
  next?: string;
}) {
  const { state, pending, formProps } = useActionForm(action);
  const signingUp = mode === "sign-up";
  return (
    <form {...formProps} className="space-y-4" noValidate>
      {state?.error && <Alert tone="danger">{state.error}</Alert>}
      {state?.message && <Alert tone="success">{state.message}</Alert>}
      {next && <input type="hidden" name="next" value={next} />}
      <Field id="email" label="Email" error={state?.fieldErrors?.email}>
        <Input id="email" name="email" type="email" autoComplete="email" required aria-invalid={Boolean(state?.fieldErrors?.email)} />
      </Field>
      <Field id="password" label="Password" hint={signingUp ? "At least 10 characters." : undefined} error={state?.fieldErrors?.password}>
        <Input
          id="password"
          name="password"
          type="password"
          autoComplete={signingUp ? "new-password" : "current-password"}
          required
          minLength={signingUp ? 10 : undefined}
          aria-invalid={Boolean(state?.fieldErrors?.password)}
        />
      </Field>
      <SubmitButton pending={pending} className="w-full" pendingText={signingUp ? "Creating account…" : "Signing in…"}>
        {signingUp ? "Create account" : "Sign in"}
      </SubmitButton>
      <p className="text-center text-sm text-muted">
        {signingUp ? (
          <>Already have an account? <Link href="/sign-in" className="font-medium text-accent underline-offset-2 hover:underline">Sign in</Link></>
        ) : (
          <>New to JobPilot? <Link href="/sign-up" className="font-medium text-accent underline-offset-2 hover:underline">Create an account</Link></>
        )}
      </p>
    </form>
  );
}
