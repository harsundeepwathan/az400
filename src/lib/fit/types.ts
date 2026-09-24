import { z } from "zod";
import { MATCH_TYPES, RECOMMENDATIONS, SOURCE_TYPES, type MatchType, type Recommendation, type SourceType } from "../domain";

/** One citable fact from the user's profile. `id` is the database id of the row. */
export type SourceItem = {
  id: string;
  type: SourceType;
  label: string;
  text: string;
  /** False for evidence the user has not yet verified. */
  verified: boolean;
};

export type Requirement = { id: string; text: string; kind: "must" | "nice" };

export type FitInput = {
  job: {
    title: string;
    company: string;
    location: string;
    workplace_type: string;
    salary_max: number | null;
    currency: string;
    description: string;
    requirements: Requirement[];
  };
  profile: {
    current_title: string;
    target_titles: string[];
    preferred_locations: string[];
    workplace_preference: string;
    willing_to_relocate: boolean;
    work_authorization_notes: string;
    target_salary: number | null;
    salary_currency: string;
    years_experience: number | null;
  };
  sources: SourceItem[];
};

/** What an AI provider (or the heuristic engine) must return. Validated with Zod. */
export const fitDraftSchema = z.object({
  requirements: z
    .array(
      z.object({
        requirement_id: z.string().max(100),
        match_type: z.enum(MATCH_TYPES),
        source_ids: z.array(z.string().max(100)).max(5),
        explanation: z.string().max(600),
      }),
    )
    .max(60),
  seniority: z.object({
    alignment: z.enum(["aligned", "below", "above", "unclear"]),
    explanation: z.string().max(600),
  }),
  location_considerations: z.array(z.string().max(600)).max(8),
  emphasize: z.array(z.object({ source_id: z.string().max(100), reason: z.string().max(400) })).max(8),
  questions: z.array(z.string().max(400)).max(10),
  explanation: z.string().max(1500),
});
export type FitDraft = z.infer<typeof fitDraftSchema>;

export type CoverageBucket = { total: number; strong: number; transferable: number; unclear: number; missing: number };

export type FitMatch = {
  requirement_text: string;
  requirement_kind: "must" | "nice";
  match_type: MatchType;
  explanation: string;
  source_type: SourceType | null;
  source_id: string | null;
  source_label: string;
  needs_confirmation: boolean;
};

export type FitResult = {
  score: number;
  recommendation: Recommendation;
  explanation: string;
  coverage: { must: CoverageBucket; nice: CoverageBucket };
  matches: FitMatch[];
  seniority: FitDraft["seniority"];
  location_considerations: string[];
  emphasize: Array<{ source_id: string; source_type: SourceType; label: string; reason: string }>;
  questions: string[];
  warnings: string[];
};

export const sourceTypeSchema = z.enum(SOURCE_TYPES);
export const recommendationSchema = z.enum(RECOMMENDATIONS);
