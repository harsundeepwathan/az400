import Link from "next/link";
import { FitScore, MatchBadge, ProviderNotice, RecommendationBadge } from "@/components/badges";
import { Alert, Badge, Card, CardHeader } from "@/components/ui/display";
import type { StoredFit } from "@/lib/data/jobs";
import type { MatchType, SourceType } from "@/lib/domain";
import type { FitMatch } from "@/lib/fit/types";

function sourceHref(type: SourceType | null, id: string | null, resumeId: string | null) {
  if (!type || !id) return null;
  if (type === "evidence") return `/evidence/${id}`;
  return resumeId ? `/resumes/${resumeId}` : "/resumes";
}

const SOURCE_NAMES: Record<SourceType, string> = {
  skill: "Skill",
  employment: "Role",
  certification: "Certification",
  education: "Education",
  project: "Project",
  evidence: "Evidence",
  summary: "Summary",
};

const GROUPS: Array<{ type: MatchType; title: string; description: string }> = [
  { type: "strong", title: "Strong matches", description: "Directly supported by your resume or evidence." },
  { type: "transferable", title: "Transferable matches", description: "Related experience that you will need to frame." },
  { type: "unclear", title: "Evidence unclear", description: "Possibly covered, but not clearly supported yet." },
  { type: "missing", title: "Missing requirements", description: "Nothing in your profile supports these." },
];

function MatchRow({ m, resumeId }: { m: FitMatch; resumeId: string | null }) {
  const href = sourceHref(m.source_type, m.source_id, resumeId);
  return (
    <li className="py-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={m.requirement_kind === "must" ? "accent" : "neutral"}>{m.requirement_kind === "must" ? "Must-have" : "Nice-to-have"}</Badge>
        <MatchBadge type={m.match_type} />
        {m.needs_confirmation && <Badge tone="warning">Needs confirmation</Badge>}
      </div>
      <p className="mt-1.5 text-sm font-medium">{m.requirement_text}</p>
      <p className="mt-0.5 text-sm text-muted">{m.explanation}</p>
      {href && m.source_type && (
        <p className="mt-1 text-xs">
          Source: <Link href={href} className="text-accent hover:underline">{SOURCE_NAMES[m.source_type]} · {m.source_label}</Link>
        </p>
      )}
    </li>
  );
}

export function FitAnalysisView({ fit }: { fit: StoredFit }) {
  const { must, nice } = fit.coverage;
  return (
    <div className="space-y-4">
      <Card>
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-muted">Evidence-matching score</p>
            <div className="mt-1 flex items-center gap-3">
              <FitScore score={fit.score} size="lg" />
              <RecommendationBadge recommendation={fit.recommendation} />
            </div>
            <p className="mt-1 max-w-md text-xs text-muted">
              An internal measure of how much of this job&apos;s requirements your recorded evidence supports. It does not predict how an
              applicant-tracking system or recruiter will rate you.
            </p>
          </div>
          <div className="text-right text-xs text-muted">
            <ProviderNotice provider={fit.provider} />
            <p className="mt-1">Analysed {new Date(fit.created_at).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" })}</p>
          </div>
        </div>
        <p className="mt-4 text-sm">{fit.explanation}</p>
        <dl className="mt-4 grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
          <div><dt className="text-muted">Must-haves strong</dt><dd className="font-semibold tabular-nums">{must.strong} / {must.total}</dd></div>
          <div><dt className="text-muted">Must-haves missing</dt><dd className="font-semibold tabular-nums">{must.missing}</dd></div>
          <div><dt className="text-muted">Nice-to-haves covered</dt><dd className="font-semibold tabular-nums">{nice.strong + nice.transferable} / {nice.total}</dd></div>
          <div><dt className="text-muted">Needs confirmation</dt><dd className="font-semibold tabular-nums">{fit.matches.filter((m) => m.needs_confirmation).length}</dd></div>
        </dl>
        {fit.warnings.length > 0 && (
          <Alert tone="warning" className="mt-4" title="Analysis notes">
            <ul className="list-disc pl-5">{fit.warnings.map((w) => <li key={w}>{w}</li>)}</ul>
          </Alert>
        )}
      </Card>

      {fit.questions.length > 0 && (
        <Card>
          <CardHeader title="Answer before applying" description="Honest answers here make the difference between a strong application and a wasted one." />
          <ul className="list-disc space-y-1 pl-5 text-sm">{fit.questions.map((q) => <li key={q}>{q}</li>)}</ul>
        </Card>
      )}

      <div className="grid gap-4 lg:grid-cols-2">
        {GROUPS.map((g) => {
          const items = fit.matches.filter((m) => m.match_type === g.type);
          if (items.length === 0) return null;
          return (
            <Card key={g.type}>
              <CardHeader title={`${g.title} (${items.length})`} description={g.description} as="h3" />
              <ul className="-my-3 divide-y divide-line">{items.map((m, i) => <MatchRow key={i} m={m} resumeId={fit.resume_id} />)}</ul>
            </Card>
          );
        })}
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <Card>
          <CardHeader title="Seniority" as="h3" />
          <Badge tone={fit.seniority.alignment === "aligned" ? "success" : fit.seniority.alignment === "unclear" ? "neutral" : "warning"}>
            {{ aligned: "Aligned", above: "Above your level", below: "Below your level", unclear: "Unclear" }[fit.seniority.alignment]}
          </Badge>
          <p className="mt-2 text-sm text-muted">{fit.seniority.explanation}</p>
        </Card>
        <Card>
          <CardHeader title="Location and authorisation" as="h3" />
          {fit.location_considerations.length === 0 ? (
            <p className="text-sm text-muted">No concerns found.</p>
          ) : (
            <ul className="list-disc space-y-1 pl-5 text-sm">{fit.location_considerations.map((c) => <li key={c}>{c}</li>)}</ul>
          )}
        </Card>
        <Card>
          <CardHeader title="Evidence to emphasise" as="h3" />
          {fit.emphasize.length === 0 ? (
            <p className="text-sm text-muted">Add evidence items to get suggestions.</p>
          ) : (
            <ul className="space-y-2 text-sm">
              {fit.emphasize.map((e) => (
                <li key={e.source_id}>
                  <Link href={sourceHref(e.source_type, e.source_id, fit.resume_id) ?? "#"} className="font-medium text-accent hover:underline">{e.label}</Link>
                  <p className="text-xs text-muted">{e.reason}</p>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
    </div>
  );
}
