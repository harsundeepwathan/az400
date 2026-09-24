"use client";

import { useRef, useState, useTransition } from "react";
import { Upload } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Badge, Card, CardHeader } from "@/components/ui/display";
import { Field, Input, Textarea } from "@/components/ui/form";
import type { ParseResponse, SaveResponse } from "@/app/(app)/resumes/actions";
import type { ParseResult, ResumeDraft } from "@/lib/resume/schema";
import { ResumeEditor } from "./resume-editor";

type Mode = "upload" | "paste" | "manual";

const STATUS_COPY: Record<ParseResult["status"], { tone: "success" | "warning" | "danger" | "neutral"; label: string }> = {
  parsed: { tone: "success", label: "Extracted" },
  partial: { tone: "warning", label: "Partly extracted" },
  unreadable: { tone: "danger", label: "Could not read" },
  manual: { tone: "neutral", label: "Manual entry" },
};

export function NewResumeFlow({
  parse,
  save,
}: {
  parse: (fd: FormData) => Promise<ParseResponse>;
  save: (fd: FormData) => Promise<SaveResponse>;
}) {
  const [mode, setMode] = useState<Mode>("upload");
  const [file, setFile] = useState<File | null>(null);
  const [text, setText] = useState("");
  const [title, setTitle] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [preview, setPreview] = useState<ParseResult | null>(null);
  const [pending, start] = useTransition();
  const fileInput = useRef<HTMLInputElement>(null);

  function extract() {
    setError(null);
    const fd = new FormData();
    fd.set("mode", mode);
    fd.set("title", title);
    if (mode === "upload") {
      if (!file) return setError("Choose a PDF or DOCX file first.");
      fd.set("file", file);
    }
    if (mode === "paste") {
      if (text.trim().length < 50) return setError("Paste the full text of your resume.");
      fd.set("text", text);
    }
    start(async () => {
      const res = await parse(fd);
      if (!res.ok) setError(res.error);
      else setPreview(res.result);
    });
  }

  async function onSave(draft: ResumeDraft): Promise<SaveResponse> {
    const fd = new FormData();
    const effectiveMode = preview?.status === "manual" ? "manual" : mode;
    fd.set("mode", effectiveMode);
    fd.set("draft", JSON.stringify(draft));
    fd.set("parse_status", preview?.status ?? "manual");
    fd.set("parse_warnings", JSON.stringify(preview?.warnings ?? []));
    if (effectiveMode === "upload" && file) fd.set("file", file);
    if (effectiveMode === "paste") fd.set("text", text);
    return save(fd);
  }

  if (preview && preview.status !== "unreadable") {
    const s = STATUS_COPY[preview.status];
    return (
      <div className="space-y-4">
        <Card>
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 className="font-semibold">Review before saving</h2>
              <p className="text-sm text-muted">
                {preview.status === "manual"
                  ? "Enter your details below."
                  : "Everything below was copied from your resume. Check each field; nothing is saved until you choose Save."}
              </p>
            </div>
            <div className="flex items-center gap-2">
              <Badge tone={s.tone}>{s.label}</Badge>
              <Button variant="ghost" size="sm" onClick={() => setPreview(null)}>Start over</Button>
            </div>
          </div>
        </Card>
        <ResumeEditor initial={preview.draft} warnings={preview.warnings} onSave={onSave} submitLabel="Save resume" />
      </div>
    );
  }

  const tabs: Array<{ id: Mode; label: string }> = [
    { id: "upload", label: "Upload file" },
    { id: "paste", label: "Paste text" },
    { id: "manual", label: "Enter manually" },
  ];

  return (
    <Card>
      <CardHeader title="Add a resume" description="PDF or DOCX up to 5 MB. Scanned (image-only) resumes cannot be read; paste the text instead." />
      <div role="tablist" aria-label="How to add your resume" className="mb-4 inline-flex rounded-md border border-line bg-subtle p-0.5">
        {tabs.map((t) => (
          <button
            key={t.id}
            role="tab"
            type="button"
            aria-selected={mode === t.id}
            className={`rounded px-3 py-1.5 text-sm ${mode === t.id ? "bg-surface font-medium shadow-sm" : "text-muted hover:text-ink"}`}
            onClick={() => { setMode(t.id); setError(null); }}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="space-y-4">
        {preview?.status === "unreadable" && (
          <Alert tone="warning" title="We could not read enough text">
            {preview.warnings[0]}
          </Alert>
        )}
        {error && <Alert tone="danger">{error}</Alert>}

        <Field id="resume-title" label="Resume name" hint="Optional, e.g. “Platform engineering resume”.">
          <Input id="resume-title" value={title} onChange={(e) => setTitle(e.target.value)} />
        </Field>

        {mode === "upload" && (
          <div>
            <label htmlFor="resume-file" className="flex cursor-pointer flex-col items-center justify-center rounded-lg border border-dashed border-line-strong bg-subtle px-4 py-8 text-center hover:border-accent">
              <Upload className="h-5 w-5 text-muted" aria-hidden />
              <span className="mt-2 text-sm font-medium">{file ? file.name : "Choose a PDF or DOCX file"}</span>
              <span className="text-xs text-muted">{file ? `${Math.round(file.size / 1024)} KB` : "Max 5 MB"}</span>
            </label>
            <input
              ref={fileInput}
              id="resume-file"
              type="file"
              accept=".pdf,.docx,application/pdf,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
              className="sr-only"
              onChange={(e) => setFile(e.target.files?.[0] ?? null)}
            />
          </div>
        )}
        {mode === "paste" && (
          <Field id="resume-text" label="Resume text" hint="Paste everything, including section headings like Experience and Skills.">
            <Textarea id="resume-text" rows={14} value={text} onChange={(e) => setText(e.target.value)} className="font-mono text-xs" />
          </Field>
        )}
        {mode === "manual" && <p className="text-sm text-muted">You will get an empty form to fill in yourself.</p>}

        <Button onClick={extract} disabled={pending}>
          {pending ? "Reading…" : mode === "manual" ? "Continue" : "Extract and preview"}
        </Button>
      </div>
    </Card>
  );
}
