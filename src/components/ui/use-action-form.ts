"use client";

import { startTransition, useActionState, useEffect, useRef, type FormEvent } from "react";
import type { ActionState } from "@/lib/forms";

/**
 * Runs a server action from a form without React's automatic form reset, so a
 * validation error never wipes what the user typed (e.g. a pasted job
 * description). Optionally resets the form after a successful submission.
 */
export function useActionForm(
  action: (state: ActionState, fd: FormData) => Promise<ActionState>,
  { resetOnSuccess = false }: { resetOnSuccess?: boolean } = {},
) {
  const [state, formAction, pending] = useActionState(action, undefined);
  const ref = useRef<HTMLFormElement>(null);

  useEffect(() => {
    if (resetOnSuccess && state?.ok) ref.current?.reset();
  }, [state, resetOnSuccess]);

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const fd = new FormData(event.currentTarget);
    startTransition(() => formAction(fd));
  }

  return { state, pending, formProps: { ref, onSubmit } };
}
