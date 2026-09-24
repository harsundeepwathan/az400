import type { MatchType, Recommendation } from "../domain";
import type { CoverageBucket, FitDraft, FitInput, FitMatch, FitResult } from "./types";

/**
 * Turns a provider's draft into a trustworthy result:
 *  1. Every cited source must exist in the user's catalogue; unknown ids are removed.
 *  2. A "strong" or "transferable" match without a valid source becomes "unclear"
 *     and is flagged "Needs confirmation".
 *  3. Matches resting only on the professional summary or on unverified evidence
 *     are flagged "Needs confirmation" (summary-only matches are capped at "unclear").
 *  4. The score is recomputed deterministically from coverage; the provider's
 *     opinion of the score is never used.
 */

export const MATCH_CREDIT: Record<MatchType, number> = { strong: 1, transferable: 0.6, unclear: 0.25, missing: 0 };
export const MUST_WEIGHT = 0.75;
export const NICE_WEIGHT = 0.25;

function emptyBucket(): CoverageBucket {
  return { total: 0, strong: 0, transferable: 0, unclear: 0, missing: 0 };
}

export function computeCoverage(matches: Pick<FitMatch, "requirement_kind" | "match_type">[]) {
  const coverage = { must: emptyBucket(), nice: emptyBucket() };
  for (const m of matches) {
    const bucket = coverage[m.requirement_kind];
    bucket.total++;
    bucket[m.match_type]++;
  }
  return coverage;
}

function bucketRatio(b: CoverageBucket): number {
  if (b.total === 0) return 0;
  return (b.strong * MATCH_CREDIT.strong + b.transferable * MATCH_CREDIT.transferable + b.unclear * MATCH_CREDIT.unclear) / b.total;
}

/** Internal evidence-matching score, 0–100. Not a prediction of any ATS outcome. */
export function computeFitScore(coverage: { must: CoverageBucket; nice: CoverageBucket }): number {
  const { must, nice } = coverage;
  if (must.total === 0 && nice.total === 0) return 0;
  let ratio: number;
  if (must.total === 0) ratio = bucketRatio(nice);
  else if (nice.total === 0) ratio = bucketRatio(must);
  else ratio = MUST_WEIGHT * bucketRatio(must) + NICE_WEIGHT * bucketRatio(nice);
  return Math.max(0, Math.min(100, Math.round(ratio * 100)));
}

export function recommend(score: number, coverage: { must: CoverageBucket }): Recommendation {
  const missingMust = coverage.must.missing;
  if (score >= 75 && missingMust === 0) return "strong_apply";
  if (score >= 55 && missingMust <= 1) return "apply";
  if (score >= 35) return "stretch";
  return "low_value";
}

export function finalizeFit(draft: FitDraft, input: FitInput): FitResult {
  const warnings: string[] = [];
  const sources = new Map(input.sources.map((s) => [s.id, s]));
  const drafted = new Map(draft.requirements.map((r) => [r.requirement_id, r]));

  const unknownRequirements = draft.requirements.filter((r) => !input.job.requirements.some((q) => q.id === r.requirement_id));
  if (unknownRequirements.length) warnings.push(`Ignored ${unknownRequirements.length} assessment(s) for requirements that are not in this job.`);

  let invalidCitations = 0;
  const matches: FitMatch[] = input.job.requirements.map((req) => {
    const d = drafted.get(req.id);
    if (!d) {
      return {
        requirement_text: req.text,
        requirement_kind: req.kind,
        match_type: "unclear",
        explanation: "This requirement was not assessed. Review it yourself.",
        source_type: null,
        source_id: null,
        source_label: "",
        needs_confirmation: true,
      };
    }

    const valid = d.source_ids.map((id) => sources.get(id)).filter((s) => s !== undefined);
    invalidCitations += d.source_ids.length - valid.length;
    let matchType: MatchType = d.match_type;
    let needsConfirmation = false;
    let explanation = d.explanation;

    if (matchType === "missing") {
      return {
        requirement_text: req.text,
        requirement_kind: req.kind,
        match_type: "missing",
        explanation,
        source_type: null,
        source_id: null,
        source_label: "",
        needs_confirmation: false,
      };
    }

    const primary = valid.find((s) => s.type !== "summary" && s.verified) ?? valid.find((s) => s.type !== "summary") ?? valid[0];

    if (!primary) {
      if (matchType === "strong" || matchType === "transferable") {
        explanation = `${explanation} (No source in your profile supports this claim.)`.trim();
      }
      matchType = "unclear";
      needsConfirmation = true;
    } else if (primary.type === "summary") {
      if (matchType !== "unclear") matchType = "unclear";
      needsConfirmation = true;
    } else if (!primary.verified) {
      needsConfirmation = true;
    }

    return {
      requirement_text: req.text,
      requirement_kind: req.kind,
      match_type: matchType,
      explanation,
      source_type: primary?.type ?? null,
      source_id: primary?.id ?? null,
      source_label: primary?.label ?? "",
      needs_confirmation: needsConfirmation,
    };
  });
  if (invalidCitations) warnings.push(`Removed ${invalidCitations} citation(s) that did not match anything in your profile.`);

  const emphasize = draft.emphasize.flatMap((e) => {
    const s = sources.get(e.source_id);
    return s && s.type !== "summary" ? [{ source_id: s.id, source_type: s.type, label: s.label, reason: e.reason }] : [];
  });

  const coverage = computeCoverage(matches);
  const score = computeFitScore(coverage);
  return {
    score,
    recommendation: recommend(score, coverage),
    explanation: draft.explanation,
    coverage,
    matches,
    seniority: draft.seniority,
    location_considerations: draft.location_considerations,
    emphasize,
    questions: draft.questions,
    warnings,
  };
}
