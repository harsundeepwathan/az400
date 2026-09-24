"use client";

import { useState, useTransition } from "react";
import { useFieldArray, useForm, type UseFormRegister } from "react-hook-form";
import { Plus, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Card, CardHeader } from "@/components/ui/display";
import { Checkbox, Field, Input, Textarea } from "@/components/ui/form";
import type { ResumeDraft } from "@/lib/resume/schema";

type FormValues = {
  title: string;
  contact: { name: string; email: string; phone: string; location: string; links: string };
  summary: string;
  employment: Array<{
    id?: string; employer: string; title: string; location: string; start_date: string; end_date: string;
    is_current: boolean; responsibilities: string; achievements: string;
  }>;
  education: ResumeDraft["education"];
  certifications: ResumeDraft["certifications"];
  skills: ResumeDraft["skills"];
  projects: Array<{ id?: string; name: string; description: string; skills: string; url: string }>;
  languages: string;
};

const splitLines = (v: string) => v.split("\n").map((s) => s.trim()).filter(Boolean);
const splitComma = (v: string) => v.split(/[,\n]/).map((s) => s.trim()).filter(Boolean);

function toForm(d: ResumeDraft): FormValues {
  return {
    title: d.title,
    contact: { ...d.contact, links: d.contact.links.join("\n") },
    summary: d.summary,
    employment: d.employment.map((e) => ({ ...e, responsibilities: e.responsibilities.join("\n"), achievements: e.achievements.join("\n") })),
    education: d.education,
    certifications: d.certifications,
    skills: d.skills,
    projects: d.projects.map((p) => ({ ...p, skills: p.skills.join(", ") })),
    languages: d.languages.join(", "),
  };
}

function toDraft(v: FormValues): ResumeDraft {
  return {
    title: v.title.trim(),
    contact: { ...v.contact, links: splitLines(v.contact.links) },
    summary: v.summary.trim(),
    employment: v.employment.map((e) => ({
      ...e,
      end_date: e.is_current ? "" : e.end_date.trim(),
      start_date: e.start_date.trim(),
      responsibilities: splitLines(e.responsibilities),
      achievements: splitLines(e.achievements),
    })),
    education: v.education,
    certifications: v.certifications.filter((c) => c.name.trim()),
    skills: v.skills.filter((s) => s.name.trim()),
    projects: v.projects.filter((p) => p.name.trim()).map((p) => ({ ...p, skills: splitComma(p.skills) })),
    languages: splitComma(v.languages),
  };
}

export type SaveResult = { ok: boolean; error?: string; message?: string } | undefined;

function RemoveButton({ onClick, label }: { onClick: () => void; label: string }) {
  return (
    <Button variant="ghost" size="sm" onClick={onClick} aria-label={label} className="text-muted">
      <X className="h-4 w-4" aria-hidden />
    </Button>
  );
}

const DATE_HINT = "YYYY or YYYY-MM";

function EmploymentFields({ index, register, onRemove }: { index: number; register: UseFormRegister<FormValues>; onRemove: () => void }) {
  const p = `employment.${index}` as const;
  const id = (k: string) => `emp-${index}-${k}`;
  return (
    <fieldset className="rounded-md border border-line p-4">
      <div className="mb-3 flex items-center justify-between">
        <legend className="text-sm font-semibold">Role {index + 1}</legend>
        <RemoveButton onClick={onRemove} label={`Remove role ${index + 1}`} />
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field id={id("title")} label="Job title"><Input id={id("title")} {...register(`${p}.title`)} /></Field>
        <Field id={id("employer")} label="Employer"><Input id={id("employer")} {...register(`${p}.employer`)} /></Field>
        <Field id={id("location")} label="Location"><Input id={id("location")} {...register(`${p}.location`)} /></Field>
        <div className="grid grid-cols-2 gap-3">
          <Field id={id("start")} label="Start" hint={DATE_HINT}><Input id={id("start")} {...register(`${p}.start_date`, { pattern: /^(\d{4}(-\d{2})?)?$/ })} /></Field>
          <Field id={id("end")} label="End" hint={DATE_HINT}><Input id={id("end")} {...register(`${p}.end_date`, { pattern: /^(\d{4}(-\d{2})?)?$/ })} /></Field>
        </div>
        <Checkbox {...register(`${p}.is_current`)} label="I currently work here" className="sm:col-span-2" />
        <Field id={id("resp")} label="Responsibilities" hint="One per line." className="sm:col-span-2">
          <Textarea id={id("resp")} rows={4} {...register(`${p}.responsibilities`)} />
        </Field>
        <Field id={id("ach")} label="Achievements" hint="One per line. Only include results you can stand behind." className="sm:col-span-2">
          <Textarea id={id("ach")} rows={4} {...register(`${p}.achievements`)} />
        </Field>
      </div>
    </fieldset>
  );
}

export function ResumeEditor({
  initial,
  onSave,
  submitLabel = "Save resume",
  warnings = [],
}: {
  initial: ResumeDraft;
  onSave: (draft: ResumeDraft) => Promise<SaveResult>;
  submitLabel?: string;
  warnings?: string[];
}) {
  const { register, control, handleSubmit, formState } = useForm<FormValues>({ defaultValues: toForm(initial) });
  const employment = useFieldArray({ control, name: "employment" });
  const education = useFieldArray({ control, name: "education" });
  const certifications = useFieldArray({ control, name: "certifications" });
  const skills = useFieldArray({ control, name: "skills" });
  const projects = useFieldArray({ control, name: "projects" });
  const [result, setResult] = useState<SaveResult>();
  const [pending, start] = useTransition();

  const submit = handleSubmit((values) =>
    start(async () => {
      setResult(await onSave(toDraft(values)));
    }),
  );

  const hasDateErrors = Boolean(formState.errors.employment);

  return (
    <form onSubmit={submit} className="space-y-4" noValidate>
      {warnings.length > 0 && (
        <Alert tone="warning" title="Check these before saving">
          <ul className="list-disc pl-5">{warnings.map((w) => <li key={w}>{w}</li>)}</ul>
        </Alert>
      )}

      <Card>
        <CardHeader title="Resume" description="Name this resume so you can tell versions apart." />
        <div className="grid gap-3 sm:grid-cols-2">
          <Field id="title" label="Resume name" error={formState.errors.title ? "Give this resume a name" : undefined}>
            <Input id="title" aria-invalid={Boolean(formState.errors.title)} {...register("title", { required: true })} />
          </Field>
        </div>
      </Card>

      <Card>
        <CardHeader title="Contact information" description="Stored privately. Never sent to an AI provider." />
        <div className="grid gap-3 sm:grid-cols-2">
          <Field id="c-name" label="Name"><Input id="c-name" {...register("contact.name")} /></Field>
          <Field id="c-email" label="Email"><Input id="c-email" type="email" {...register("contact.email")} /></Field>
          <Field id="c-phone" label="Phone"><Input id="c-phone" {...register("contact.phone")} /></Field>
          <Field id="c-location" label="Location"><Input id="c-location" {...register("contact.location")} /></Field>
          <Field id="c-links" label="Links" hint="One per line." className="sm:col-span-2"><Textarea id="c-links" rows={2} {...register("contact.links")} /></Field>
        </div>
      </Card>

      <Card>
        <CardHeader title="Professional summary" />
        <Field id="summary" label={<span className="sr-only">Professional summary</span>}>
          <Textarea id="summary" rows={4} {...register("summary")} />
        </Field>
      </Card>

      <Card>
        <CardHeader
          title="Employment history"
          action={
            <Button size="sm" variant="secondary" onClick={() => employment.append({ employer: "", title: "", location: "", start_date: "", end_date: "", is_current: false, responsibilities: "", achievements: "" })}>
              <Plus className="h-4 w-4" aria-hidden /> Add role
            </Button>
          }
        />
        {hasDateErrors && <Alert tone="danger" className="mb-3">Use YYYY or YYYY-MM for dates.</Alert>}
        <div className="space-y-3">
          {employment.fields.length === 0 && <p className="text-sm text-muted">No roles yet.</p>}
          {employment.fields.map((f, i) => <EmploymentFields key={f.id} index={i} register={register} onRemove={() => employment.remove(i)} />)}
        </div>
      </Card>

      <Card>
        <CardHeader title="Skills" action={<Button size="sm" variant="secondary" onClick={() => skills.append({ name: "", category: "" })}><Plus className="h-4 w-4" aria-hidden /> Add skill</Button>} />
        {skills.fields.length === 0 && <p className="text-sm text-muted">No skills yet.</p>}
        <ul className="grid gap-2 sm:grid-cols-2">
          {skills.fields.map((f, i) => (
            <li key={f.id} className="flex items-center gap-2">
              <Input aria-label={`Skill ${i + 1}`} placeholder="Skill" {...register(`skills.${i}.name`)} />
              <Input aria-label={`Skill ${i + 1} category`} placeholder="Category" className="w-32" {...register(`skills.${i}.category`)} />
              <RemoveButton onClick={() => skills.remove(i)} label={`Remove skill ${i + 1}`} />
            </li>
          ))}
        </ul>
      </Card>

      <Card>
        <CardHeader title="Certifications" action={<Button size="sm" variant="secondary" onClick={() => certifications.append({ name: "", issuer: "", issued_on: "", expires_on: "" })}><Plus className="h-4 w-4" aria-hidden /> Add</Button>} />
        {certifications.fields.length === 0 && <p className="text-sm text-muted">No certifications yet.</p>}
        <ul className="space-y-2">
          {certifications.fields.map((f, i) => (
            <li key={f.id} className="grid grid-cols-[1fr_auto] items-end gap-2 sm:grid-cols-[2fr_1fr_7rem_auto]">
              <Input aria-label="Certification name" placeholder="Name" {...register(`certifications.${i}.name`)} className="col-span-2 sm:col-span-1" />
              <Input aria-label="Issuer" placeholder="Issuer" {...register(`certifications.${i}.issuer`)} />
              <Input aria-label="Year issued" placeholder="YYYY" {...register(`certifications.${i}.issued_on`)} />
              <RemoveButton onClick={() => certifications.remove(i)} label={`Remove certification ${i + 1}`} />
            </li>
          ))}
        </ul>
      </Card>

      <Card>
        <CardHeader title="Education" action={<Button size="sm" variant="secondary" onClick={() => education.append({ institution: "", qualification: "", field_of_study: "", start_date: "", end_date: "", notes: "" })}><Plus className="h-4 w-4" aria-hidden /> Add</Button>} />
        {education.fields.length === 0 && <p className="text-sm text-muted">No education entries yet.</p>}
        <div className="space-y-3">
          {education.fields.map((f, i) => (
            <fieldset key={f.id} className="grid gap-2 rounded-md border border-line p-3 sm:grid-cols-2">
              <legend className="sr-only">Education {i + 1}</legend>
              <Input aria-label="Institution" placeholder="Institution" {...register(`education.${i}.institution`)} />
              <Input aria-label="Qualification" placeholder="Qualification" {...register(`education.${i}.qualification`)} />
              <Input aria-label="Field of study" placeholder="Field of study" {...register(`education.${i}.field_of_study`)} />
              <div className="flex gap-2">
                <Input aria-label="Start year" placeholder="Start" {...register(`education.${i}.start_date`)} />
                <Input aria-label="End year" placeholder="End" {...register(`education.${i}.end_date`)} />
                <RemoveButton onClick={() => education.remove(i)} label={`Remove education ${i + 1}`} />
              </div>
            </fieldset>
          ))}
        </div>
      </Card>

      <Card>
        <CardHeader title="Projects" action={<Button size="sm" variant="secondary" onClick={() => projects.append({ name: "", description: "", skills: "", url: "" })}><Plus className="h-4 w-4" aria-hidden /> Add</Button>} />
        {projects.fields.length === 0 && <p className="text-sm text-muted">No projects yet.</p>}
        <div className="space-y-3">
          {projects.fields.map((f, i) => (
            <fieldset key={f.id} className="grid gap-2 rounded-md border border-line p-3 sm:grid-cols-2">
              <legend className="sr-only">Project {i + 1}</legend>
              <Input aria-label="Project name" placeholder="Project name" {...register(`projects.${i}.name`)} />
              <div className="flex gap-2">
                <Input aria-label="Project link" placeholder="https://…" {...register(`projects.${i}.url`)} />
                <RemoveButton onClick={() => projects.remove(i)} label={`Remove project ${i + 1}`} />
              </div>
              <Textarea aria-label="Project description" placeholder="Description" rows={2} className="sm:col-span-2" {...register(`projects.${i}.description`)} />
              <Input aria-label="Project skills" placeholder="Skills, comma separated" className="sm:col-span-2" {...register(`projects.${i}.skills`)} />
            </fieldset>
          ))}
        </div>
      </Card>

      <Card>
        <CardHeader title="Languages" />
        <Field id="languages" label={<span className="sr-only">Languages</span>} hint="Comma separated.">
          <Input id="languages" {...register("languages")} />
        </Field>
      </Card>

      <div className="sticky bottom-0 -mx-4 flex flex-wrap items-center gap-3 border-t border-line bg-canvas/95 px-4 py-3 backdrop-blur sm:mx-0 sm:rounded-lg sm:border">
        <Button type="submit" disabled={pending}>{pending ? "Saving…" : submitLabel}</Button>
        {result?.error && <p role="alert" className="text-sm font-medium text-danger">{result.error}</p>}
        {result?.ok && result.message && <p role="status" className="text-sm text-success">{result.message}</p>}
      </div>
    </form>
  );
}
