import { z } from "zod";
import type { Requirement, SourceItem } from "../fit/types";

export const requirementsDraftSchema = z.object({
  requirements: z
    .array(z.object({ text: z.string().min(3).max(400), kind: z.enum(["must", "nice"]) }))
    .max(30),
});
export type RequirementsDraft = z.infer<typeof requirementsDraftSchema>;

export type Bullet = { id: string; employment_id: string; role: string; text: string };

export type MaterialsInput = {
  job: { title: string; company: string; description: string; requirements: Requirement[] };
  profile: { current_title: string; years_experience: number | null; summary: string };
  /** Requirement coverage already validated by the fit engine. */
  supported: Array<{ requirement: string; source_id: string; source_label: string }>;
  gaps: string[];
  bullets: Bullet[];
  sources: SourceItem[];
};

export const materialsDraftSchema = z.object({
  summary: z.string().max(1500),
  bullet_suggestions: z
    .array(
      z.object({
        bullet_id: z.string().max(200),
        suggested: z.string().max(600),
        rationale: z.string().max(400),
      }),
    )
    .max(12),
  keywords: z.array(z.string().max(60)).max(25),
  cover_letter: z.string().max(6000),
  outreach_message: z.string().max(1500),
});
export type MaterialsDraft = z.infer<typeof materialsDraftSchema>;

export type PrepInput = {
  job: { title: string; company: string; description: string; requirements: Requirement[] };
  supported: Array<{ requirement: string; source_label: string }>;
  gaps: string[];
  evidence: Array<{ id: string; title: string; situation: string; action: string; result: string; verified: boolean }>;
  interview_kind: string | null;
};

export const prepDraftSchema = z.object({
  technical_questions: z.array(z.object({ question: z.string().max(400), requirement: z.string().max(400) })).max(12),
  behavioural_questions: z.array(z.string().max(400)).max(10),
  company_questions: z.array(z.string().max(400)).max(8),
  star_stories: z
    .array(
      z.object({
        evidence_id: z.string().max(100),
        prompt: z.string().max(400),
        situation: z.string().max(800),
        action: z.string().max(800),
        result: z.string().max(800),
      }),
    )
    .max(8),
  questions_to_ask: z.array(z.string().max(400)).max(10),
  risk_areas: z.array(z.object({ area: z.string().max(400), preparation: z.string().max(600) })).max(8),
});
export type PrepDraft = z.infer<typeof prepDraftSchema>;
