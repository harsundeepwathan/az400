"use client";

import { useActionForm } from "@/components/ui/use-action-form";
import { useTransition } from "react";
import { X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input, Select } from "@/components/ui/form";
import { SubmitButton } from "@/components/ui/submit-button";
import type { ActionState } from "@/lib/forms";
import type { Requirement } from "@/lib/fit/types";

export function RequirementsEditor({
  requirements,
  addAction,
  toggleAction,
  deleteAction,
}: {
  requirements: Requirement[];
  addAction: (s: ActionState, fd: FormData) => Promise<ActionState>;
  toggleAction: (id: string, kind: "must" | "nice") => Promise<void>;
  deleteAction: (id: string) => Promise<void>;
}) {
  const { state, pending: adding, formProps } = useActionForm(addAction, { resetOnSuccess: true });
  const [pending, start] = useTransition();
  return (
    <div>
      {requirements.length === 0 ? (
        <p className="text-sm text-muted">No requirements yet. Add the key ones from the job description.</p>
      ) : (
        <ul className="divide-y divide-line">
          {requirements.map((r) => (
            <li key={r.id} className="flex items-start gap-2 py-2">
              <button
                type="button"
                disabled={pending}
                onClick={() => start(() => toggleAction(r.id, r.kind === "must" ? "nice" : "must"))}
                className={`mt-0.5 shrink-0 rounded border px-1.5 py-0.5 text-xs font-medium ${r.kind === "must" ? "border-accent/30 bg-accent-soft text-accent-strong" : "border-line bg-subtle text-muted"}`}
                aria-label={`${r.kind === "must" ? "Must-have" : "Nice-to-have"}. Switch to ${r.kind === "must" ? "nice-to-have" : "must-have"}`}
              >
                {r.kind === "must" ? "Must" : "Nice"}
              </button>
              <span className="flex-1 text-sm">{r.text}</span>
              <Button variant="ghost" size="sm" disabled={pending} onClick={() => start(() => deleteAction(r.id))} aria-label={`Remove requirement: ${r.text}`}>
                <X className="h-4 w-4" aria-hidden />
              </Button>
            </li>
          ))}
        </ul>
      )}
      <form {...formProps} className="mt-3 flex flex-wrap gap-2">
        <label htmlFor="req-text" className="sr-only">New requirement</label>
        <Input id="req-text" name="text" placeholder="Add a requirement" className="min-w-0 flex-1" aria-invalid={Boolean(state?.fieldErrors?.text)} />
        <label htmlFor="req-kind" className="sr-only">Requirement type</label>
        <Select id="req-kind" name="kind" className="w-32">
          <option value="must">Must-have</option>
          <option value="nice">Nice-to-have</option>
        </Select>
        <SubmitButton pending={adding} variant="secondary" pendingText="Adding…">Add</SubmitButton>
      </form>
      {state?.fieldErrors?.text && <p className="mt-1 text-xs text-danger">{state.fieldErrors.text}</p>}
    </div>
  );
}
