import type { MatchType } from "../domain";
import { familyOf, keywords, requiredYears } from "./keywords";
import type { FitDraft, FitInput, SourceItem } from "./types";

/**
 * Deterministic evidence matcher. Used by the mock AI provider and as the
 * offline baseline. It only ever cites sources that exist in `input.sources`.
 */

const TYPE_PRIORITY: Record<SourceItem["type"], number> = {
  evidence: 6,
  employment: 5,
  certification: 4,
  project: 3,
  education: 3,
  skill: 2,
  summary: 0,
};

const SENIORITY: Array<[RegExp, number]> = [
  [/\b(chief|vp|vice president|director|head of)\b/i, 5],
  [/\b(principal|staff|lead|manager)\b/i, 4],
  [/\b(senior|sr\.?)\b/i, 3],
  [/\b(junior|jr\.?|graduate|entry[- ]level|associate)\b/i, 1],
  [/\b(intern|internship|apprentice)\b/i, 0],
];

export function seniorityLevel(title: string): number | null {
  if (!title.trim()) return null;
  for (const [re, level] of SENIORITY) if (re.test(title)) return level;
  return 2;
}

type Scored = { source: SourceItem; coverage: number; overlap: string[] };

function bestSources(reqTokens: Set<string>, sources: SourceItem[], sourceTokens: Map<string, Set<string>>): Scored[] {
  const scored: Scored[] = [];
  for (const source of sources) {
    const tokens = sourceTokens.get(source.id)!;
    const overlap = [...reqTokens].filter((t) => tokens.has(t));
    if (overlap.length === 0) continue;
    scored.push({ source, coverage: overlap.length / reqTokens.size, overlap });
  }
  return scored.sort(
    (a, b) =>
      b.coverage - a.coverage ||
      Number(b.source.verified) - Number(a.source.verified) ||
      TYPE_PRIORITY[b.source.type] - TYPE_PRIORITY[a.source.type],
  );
}

function classifyCoverage(best: Scored | undefined): MatchType {
  if (!best) return "missing";
  if (best.source.type === "summary") return "unclear";
  if (best.coverage >= 0.6) return "strong";
  if (best.coverage >= 0.34) return "transferable";
  // A single incidental word in common is not evidence.
  return best.coverage > 0.25 ? "unclear" : "missing";
}

const ORDER: MatchType[] = ["missing", "unclear", "transferable", "strong"];
const weaker = (a: MatchType, b: MatchType) => (ORDER.indexOf(a) <= ORDER.indexOf(b) ? a : b);

export function heuristicFit(input: FitInput): FitDraft {
  const { job, profile, sources } = input;
  const sourceTokens = new Map(sources.map((s) => [s.id, keywords(`${s.label} ${s.text}`)]));
  const employment = sources.filter((s) => s.type === "employment");

  const requirements: FitDraft["requirements"] = job.requirements.map((req) => {
    const years = requiredYears(req.text);
    const tokens = keywords(req.text);

    let yearsMatch: MatchType | null = null;
    let yearsNote = "";
    if (years !== null) {
      const have = profile.years_experience;
      if (have === null) {
        yearsMatch = "unclear";
        yearsNote = `Requires ${years}+ years; your role dates are incomplete.`;
      } else if (have >= years) {
        yearsMatch = "strong";
        yearsNote = `Requires ${years}+ years; your listed roles span about ${have} years.`;
      } else if (have >= years * 0.7) {
        yearsMatch = "transferable";
        yearsNote = `Requires ${years}+ years; your listed roles span about ${have} years.`;
      } else {
        yearsMatch = "missing";
        yearsNote = `Requires ${years}+ years; your listed roles span about ${have} years.`;
      }
    }

    if (tokens.size === 0) {
      if (yearsMatch) {
        return {
          requirement_id: req.id,
          match_type: yearsMatch,
          source_ids: yearsMatch === "missing" || !employment[0] ? [] : [employment[0].id],
          explanation: yearsNote,
        };
      }
      return {
        requirement_id: req.id,
        match_type: "unclear",
        source_ids: [],
        explanation: "This requirement is too general to match automatically. Decide whether your experience covers it.",
      };
    }

    const ranked = bestSources(tokens, sources, sourceTokens);
    const best = ranked[0];
    let match = classifyCoverage(best);
    let explanation: string;
    let sourceIds = best ? ranked.slice(0, 2).map((r) => r.source.id) : [];

    if (best && match !== "missing") {
      explanation =
        best.source.type === "summary"
          ? `Only your professional summary mentions ${best.overlap.join(", ")}; no role or evidence item backs it up yet.`
          : `Your ${best.source.type === "employment" ? "role" : best.source.type} “${best.source.label}” mentions ${best.overlap.join(", ")}.`;
    } else {
      explanation = "No supporting evidence found in your resume or evidence vault.";
    }

    // Related technology from the same family counts as transferable, never strong.
    if (match === "missing" || match === "unclear") {
      for (const token of tokens) {
        const family = familyOf(token);
        if (!family) continue;
        const related = sources.find((s) => {
          if (s.type === "summary") return false;
          const st = sourceTokens.get(s.id)!;
          return [...st].some((t) => t !== token && familyOf(t) === family);
        });
        if (related) {
          const relatedToken = [...sourceTokens.get(related.id)!].find((t) => t !== token && familyOf(t) === family);
          match = "transferable";
          sourceIds = [related.id];
          explanation = `Related ${family} experience (${relatedToken}) in “${related.label}”, but not ${token} itself.`;
          break;
        }
      }
    }

    if (yearsMatch) {
      match = weaker(match, yearsMatch);
      explanation = `${yearsNote} ${explanation}`;
    }
    if (match === "missing") sourceIds = [];

    return { requirement_id: req.id, match_type: match, source_ids: sourceIds, explanation };
  });

  // Seniority
  const jobLevel = seniorityLevel(job.title);
  const userLevel = seniorityLevel(profile.current_title);
  let seniority: FitDraft["seniority"];
  if (jobLevel === null || userLevel === null) {
    seniority = { alignment: "unclear", explanation: "Add your current or most recent role to compare seniority." };
  } else if (jobLevel - userLevel >= 2) {
    seniority = { alignment: "above", explanation: `“${job.title}” appears to be more than one level above your current role “${profile.current_title}”.` };
  } else if (userLevel - jobLevel >= 1) {
    seniority = { alignment: "below", explanation: `“${job.title}” appears to be below the level of your current role “${profile.current_title}”.` };
  } else {
    seniority = { alignment: "aligned", explanation: `“${job.title}” is in line with or one step up from “${profile.current_title}”.` };
  }

  // Location, work authorisation, salary
  const considerations: string[] = [];
  const preferred = profile.preferred_locations.map((l) => l.toLowerCase());
  const jobLocation = job.location.toLowerCase();
  if (job.workplace_type === "remote") {
    if (profile.workplace_preference === "onsite") considerations.push("This role is remote; you said you prefer working onsite.");
  } else if (job.workplace_type === "onsite" || job.workplace_type === "hybrid") {
    const inPreferred = preferred.some((p) => p && (jobLocation.includes(p) || p.includes(jobLocation)));
    if (job.location && !inPreferred) {
      considerations.push(
        profile.willing_to_relocate
          ? `The role is ${job.workplace_type} in ${job.location}, outside your preferred locations. You said you are open to relocating.`
          : `The role is ${job.workplace_type} in ${job.location}, outside your preferred locations, and you said you are not open to relocating.`,
      );
    }
    if (profile.workplace_preference === "remote") considerations.push(`The role is ${job.workplace_type}; you said you prefer remote work.`);
  } else {
    considerations.push("The job description does not state whether the role is remote, hybrid or onsite.");
  }

  const authSentence = job.description
    .split(/(?<=[.!?])\s+|\n/)
    .find((s) => /\b(visa|sponsor(ship)?|right to work|work authori[sz]ation|authori[sz]ed to work|citizen(ship)?|security clearance|work permit)\b/i.test(s));
  if (authSentence) {
    considerations.push(
      profile.work_authorization_notes
        ? `The job mentions work authorisation: “${authSentence.trim().slice(0, 200)}”. Compare this with your notes: “${profile.work_authorization_notes.slice(0, 200)}”.`
        : `The job mentions work authorisation: “${authSentence.trim().slice(0, 200)}”. Add your work-authorisation notes in Settings.`,
    );
  }
  if (job.salary_max && profile.target_salary && job.currency === profile.salary_currency && job.salary_max < profile.target_salary) {
    considerations.push(`The advertised maximum salary (${job.currency} ${job.salary_max.toLocaleString("en-US")}) is below your target of ${profile.salary_currency} ${profile.target_salary.toLocaleString("en-US")}.`);
  }

  // Evidence to emphasise: strongest supported requirements first.
  const emphasize: FitDraft["emphasize"] = [];
  const reqText = new Map(job.requirements.map((r) => [r.id, r.text]));
  for (const r of requirements.filter((x) => x.match_type === "strong" || x.match_type === "transferable")) {
    for (const id of r.source_ids) {
      const s = sources.find((x) => x.id === id);
      if (!s || s.type === "summary" || emphasize.some((e) => e.source_id === id)) continue;
      emphasize.push({ source_id: id, reason: `Supports: ${reqText.get(r.requirement_id)}` });
    }
    if (emphasize.length >= 5) break;
  }

  const questions: string[] = [];
  for (const r of requirements) {
    const req = job.requirements.find((x) => x.id === r.requirement_id);
    if (!req || req.kind !== "must") continue;
    if (r.match_type === "missing") questions.push(`Do you have experience with “${req.text}”? If so, add an evidence item describing it; if not, decide whether this gap rules the role out.`);
    else if (r.match_type === "unclear") questions.push(`Can you point to a specific example for “${req.text}”?`);
    if (questions.length >= 6) break;
  }
  if (authSentence && !profile.work_authorization_notes) questions.push("Do you meet the work-authorisation requirement mentioned in this job description?");

  const must = requirements.filter((r) => job.requirements.find((x) => x.id === r.requirement_id)?.kind === "must");
  const strongMust = must.filter((r) => r.match_type === "strong").length;
  const missingMust = must.filter((r) => r.match_type === "missing").length;
  const explanation =
    job.requirements.length === 0
      ? "No requirements were identified in this job description. Add requirements on the job page to get a meaningful comparison."
      : `${strongMust} of ${must.length} must-have requirements are strongly supported by your resume or evidence vault` +
        (missingMust ? `, and ${missingMust} have no supporting evidence.` : ".");

  return {
    requirements,
    seniority,
    location_considerations: considerations,
    emphasize,
    questions: questions.slice(0, 10),
    explanation,
  };
}
