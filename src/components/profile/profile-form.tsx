"use client";

import { useActionForm } from "@/components/ui/use-action-form";
import { Alert } from "@/components/ui/display";
import { Checkbox, Field, Input, Select, Textarea } from "@/components/ui/form";
import { SubmitButton } from "@/components/ui/submit-button";
import { EMPLOYMENT_TYPES, EMPLOYMENT_TYPE_LABELS } from "@/lib/domain";
import type { ActionState } from "@/lib/forms";

export type ProfileFormValues = {
  full_name: string;
  current_title: string;
  target_roles: string[];
  preferred_locations: string[];
  workplace_preference: string;
  target_salary: number | null;
  salary_currency: string;
  employment_types: string[];
  willing_to_relocate: boolean;
  work_authorization_notes: string;
  search_started_on: string | null;
};

export function ProfileForm({
  action,
  initial,
  submitLabel,
}: {
  action: (s: ActionState, fd: FormData) => Promise<ActionState>;
  initial: ProfileFormValues;
  submitLabel: string;
}) {
  const { state, pending, formProps } = useActionForm(action);
  const err = state?.fieldErrors ?? {};
  const invalid = (k: string) => (err[k] ? { "aria-invalid": true, "aria-describedby": `${k}-error` } : {});

  return (
    <form {...formProps} className="space-y-6" noValidate>
      {state?.error && <Alert tone="danger">{state.error}</Alert>}
      {state?.message && <Alert tone="success">{state.message}</Alert>}

      <fieldset className="grid gap-4 sm:grid-cols-2">
        <legend className="mb-2 text-sm font-semibold text-muted">About you</legend>
        <Field id="full_name" label="Full name" error={err.full_name}>
          <Input id="full_name" name="full_name" defaultValue={initial.full_name} autoComplete="name" required {...invalid("full_name")} />
        </Field>
        <Field id="current_title" label="Current or most recent role" error={err.current_title}>
          <Input id="current_title" name="current_title" defaultValue={initial.current_title} placeholder="e.g. Senior Platform Engineer" />
        </Field>
      </fieldset>

      <fieldset className="grid gap-4 sm:grid-cols-2">
        <legend className="mb-2 text-sm font-semibold text-muted">What you are looking for</legend>
        <Field id="target_roles" label="Target job titles" hint="One per line." error={err.target_roles}>
          <Textarea id="target_roles" name="target_roles" rows={3} defaultValue={initial.target_roles.join("\n")} placeholder={"Platform Engineer\nSite Reliability Engineer"} {...invalid("target_roles")} />
        </Field>
        <Field id="preferred_locations" label="Preferred locations" hint="One per line. Include “Remote” if relevant." error={err.preferred_locations}>
          <Textarea id="preferred_locations" name="preferred_locations" rows={3} defaultValue={initial.preferred_locations.join("\n")} placeholder={"London\nRemote"} />
        </Field>
        <Field id="workplace_preference" label="Workplace preference" error={err.workplace_preference}>
          <Select id="workplace_preference" name="workplace_preference" defaultValue={initial.workplace_preference}>
            <option value="flexible">No strong preference</option>
            <option value="remote">Remote</option>
            <option value="hybrid">Hybrid</option>
            <option value="onsite">Onsite</option>
          </Select>
        </Field>
        <div className="grid grid-cols-[1fr_6rem] gap-3">
          <Field id="target_salary" label="Target salary (annual)" error={err.target_salary}>
            <Input id="target_salary" name="target_salary" inputMode="numeric" defaultValue={initial.target_salary ?? ""} placeholder="e.g. 95000" {...invalid("target_salary")} />
          </Field>
          <Field id="salary_currency" label="Currency" error={err.salary_currency}>
            <Input id="salary_currency" name="salary_currency" maxLength={3} defaultValue={initial.salary_currency} className="uppercase" {...invalid("salary_currency")} />
          </Field>
        </div>
        <fieldset className="space-y-2">
          <legend className="text-sm font-medium">Employment type</legend>
          <div className="flex flex-wrap gap-x-4 gap-y-2">
            {EMPLOYMENT_TYPES.map((t) => (
              <Checkbox key={t} name="employment_types" value={t} defaultChecked={initial.employment_types.includes(t)} label={EMPLOYMENT_TYPE_LABELS[t]} />
            ))}
          </div>
          {err.employment_types && <p className="text-xs font-medium text-danger">{err.employment_types}</p>}
        </fieldset>
        <div className="space-y-4">
          <Checkbox name="willing_to_relocate" defaultChecked={initial.willing_to_relocate} label="I am willing to relocate" />
          <Field id="search_started_on" label="Job search started on" error={err.search_started_on}>
            <Input id="search_started_on" name="search_started_on" type="date" defaultValue={initial.search_started_on ?? ""} />
          </Field>
        </div>
        <Field id="work_authorization_notes" label="Work-authorisation notes" hint="Private. Used only to flag roles that mention visa or right-to-work requirements." className="sm:col-span-2" error={err.work_authorization_notes}>
          <Textarea id="work_authorization_notes" name="work_authorization_notes" rows={2} defaultValue={initial.work_authorization_notes} placeholder="e.g. UK citizen; would need sponsorship for the US" />
        </Field>
      </fieldset>

      <SubmitButton pending={pending}>{submitLabel}</SubmitButton>
    </form>
  );
}
