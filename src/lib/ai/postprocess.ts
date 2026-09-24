import { detectUnsupportedClaims, type UnsupportedClaim } from "../claims";
import { corpusText } from "../fit/corpus";
import { keywords } from "../fit/keywords";
import type { MaterialsDraft, MaterialsInput, PrepDraft, PrepInput, RequirementsDraft } from "./schemas";

/** Keeps only requirements whose wording is actually present in the job description. */
export function groundRequirements(draft: RequirementsDraft, description: string): RequirementsDraft {
  const jd = keywords(description);
  const jdLower = description.toLowerCase();
  return {
    requirements: draft.requirements.filter((r) => {
      if (jdLower.includes(r.text.toLowerCase())) return true;
      const tokens = [...keywords(r.text)];
      if (tokens.length === 0) return false;
      return tokens.filter((t) => jd.has(t)).length / tokens.length >= 0.7;
    }),
  };
}

export type BulletSuggestion = MaterialsDraft["bullet_suggestions"][number] & {
  original: string;
  role: string;
  unsupported: UnsupportedClaim[];
};

export type Materials = Omit<MaterialsDraft, "bullet_suggestions"> & {
  bullet_suggestions: BulletSuggestion[];
};

export type MaterialsWarnings = { section: string; claims: UnsupportedClaim[] }[];

/**
 * Validates generated materials against the user's profile:
 * - suggestions must reference an existing bullet;
 * - keywords must be supported by the profile;
 * - every text is scanned for figures and skills that the profile does not contain.
 */
export function checkMaterials(draft: MaterialsDraft, input: MaterialsInput): { materials: Materials; warnings: MaterialsWarnings } {
  const profile = `${corpusText(input.sources)}\n${input.profile.current_title}\n${input.profile.years_experience ?? ""}`;
  const jobText = `${input.job.description}\n${input.job.requirements.map((r) => r.text).join("\n")}`;
  const allowed = [input.job.title, input.job.company];
  const bullets = new Map(input.bullets.map((b) => [b.id, b]));
  const profileTokens = keywords(profile);

  const bullet_suggestions: BulletSuggestion[] = draft.bullet_suggestions.flatMap((s) => {
    const original = bullets.get(s.bullet_id);
    if (!original) return [];
    return [
      {
        ...s,
        original: original.text,
        role: original.role,
        // A rewrite may only use facts from its own original bullet.
        unsupported: detectUnsupportedClaims(s.suggested, original.text, jobText, allowed),
      },
    ];
  });

  const warnings: MaterialsWarnings = [
    { section: "Tailored summary", claims: detectUnsupportedClaims(draft.summary, profile, jobText, allowed) },
    { section: "Cover letter", claims: detectUnsupportedClaims(draft.cover_letter, profile, jobText, allowed) },
    { section: "Recruiter message", claims: detectUnsupportedClaims(draft.outreach_message, profile, jobText, allowed) },
  ].filter((w) => w.claims.length > 0);

  return {
    materials: {
      ...draft,
      keywords: draft.keywords.filter((k) => [...keywords(k)].every((t) => profileTokens.has(t))),
      bullet_suggestions,
    },
    warnings,
  };
}

/** STAR stories may only cite verified evidence, and keep that evidence's own wording. */
export function checkPrep(draft: PrepDraft, input: PrepInput): { prep: PrepDraft; warnings: string[] } {
  const verified = new Map(input.evidence.filter((e) => e.verified).map((e) => [e.id, e]));
  const warnings: string[] = [];
  const star_stories = draft.star_stories.flatMap((s) => {
    const ev = verified.get(s.evidence_id);
    if (!ev) {
      warnings.push("Removed a STAR suggestion that was not linked to a verified evidence item.");
      return [];
    }
    return [{ ...s, situation: ev.situation, action: ev.action, result: ev.result }];
  });
  if (verified.size === 0) warnings.push("Verify evidence items in your Career Evidence Vault to get STAR story suggestions.");
  return { prep: { ...draft, star_stories }, warnings };
}
