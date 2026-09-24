"use client";

import { useActionForm } from "@/components/ui/use-action-form";
import { Alert, Card, CardHeader } from "@/components/ui/display";
import { Field, Input, Select, Textarea } from "@/components/ui/form";
import { SubmitButton } from "@/components/ui/submit-button";
import type { Job } from "@/lib/data/jobs";
import type { ActionState } from "@/lib/forms";

export function JobForm({
  action,
  initial,
  defaults,
  submitLabel,
}: {
  action: (s: ActionState, fd: FormData) => Promise<ActionState>;
  initial?: Job;
  defaults: { currency: string; today: string };
  submitLabel: string;
}) {
  const { state, pending, formProps } = useActionForm(action);
  const err = state?.fieldErrors ?? {};
  const inv = (k: string) => (err[k] ? { "aria-invalid": true as const, "aria-describedby": `${k}-error` } : {});
  return (
    <form {...formProps} className="space-y-4" noValidate>
      {state?.error && <Alert tone="danger">{state.error}</Alert>}
      <Card>
        <CardHeader title="Role" />
        <div className="grid gap-4 sm:grid-cols-2">
          <Field id="title" label="Job title" error={err.title}><Input id="title" name="title" defaultValue={initial?.title} required {...inv("title")} /></Field>
          <Field id="company" label="Company" error={err.company}><Input id="company" name="company" defaultValue={initial?.company} required {...inv("company")} /></Field>
          <Field id="location" label="Location"><Input id="location" name="location" defaultValue={initial?.location} placeholder="e.g. London" /></Field>
          <Field id="workplace_type" label="Workplace">
            <Select id="workplace_type" name="workplace_type" defaultValue={initial?.workplace_type ?? "unknown"}>
              <option value="unknown">Not stated</option>
              <option value="remote">Remote</option>
              <option value="hybrid">Hybrid</option>
              <option value="onsite">Onsite</option>
            </Select>
          </Field>
          <div className="grid grid-cols-[1fr_1fr_5.5rem] gap-2 sm:col-span-2">
            <Field id="salary_min" label="Salary from" error={err.salary_min}><Input id="salary_min" name="salary_min" inputMode="numeric" defaultValue={initial?.salary_min ?? ""} {...inv("salary_min")} /></Field>
            <Field id="salary_max" label="Salary to" error={err.salary_max}><Input id="salary_max" name="salary_max" inputMode="numeric" defaultValue={initial?.salary_max ?? ""} {...inv("salary_max")} /></Field>
            <Field id="currency" label="Currency" error={err.currency}><Input id="currency" name="currency" maxLength={3} className="uppercase" defaultValue={initial?.currency ?? defaults.currency} {...inv("currency")} /></Field>
          </div>
        </div>
      </Card>
      <Card>
        <CardHeader title="Job description" description="Paste the full text. It is stored privately and treated strictly as data during analysis." />
        <Field id="description" label={<span className="sr-only">Job description</span>} error={err.description}>
          <Textarea id="description" name="description" rows={14} defaultValue={initial?.description} {...inv("description")} />
        </Field>
      </Card>
      <Card>
        <CardHeader title="Tracking details" />
        <div className="grid gap-4 sm:grid-cols-2">
          <Field id="url" label="Job link" error={err.url}><Input id="url" name="url" type="url" defaultValue={initial?.url} placeholder="https://…" {...inv("url")} /></Field>
          <Field id="source" label="Where you found it" hint="e.g. LinkedIn, referral, company site"><Input id="source" name="source" defaultValue={initial?.source} /></Field>
          <Field id="discovered_on" label="Date discovered" error={err.discovered_on}><Input id="discovered_on" name="discovered_on" type="date" defaultValue={initial?.discovered_on ?? defaults.today} /></Field>
          <Field id="closes_on" label="Closing date" error={err.closes_on}><Input id="closes_on" name="closes_on" type="date" defaultValue={initial?.closes_on ?? ""} /></Field>
          <Field id="contact_name" label="Contact or recruiter"><Input id="contact_name" name="contact_name" defaultValue={initial?.contact_name} /></Field>
          <Field id="contact_email" label="Contact email" error={err.contact_email}><Input id="contact_email" name="contact_email" type="email" defaultValue={initial?.contact_email} {...inv("contact_email")} /></Field>
          <Field id="notes" label="Personal notes" className="sm:col-span-2"><Textarea id="notes" name="notes" rows={3} defaultValue={initial?.notes} /></Field>
        </div>
      </Card>
      <SubmitButton pending={pending}>{submitLabel}</SubmitButton>
    </form>
  );
}
