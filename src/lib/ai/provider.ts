import type { FitDraft, FitInput } from "../fit/types";
import type { MaterialsDraft, MaterialsInput, PrepDraft, PrepInput, RequirementsDraft } from "./schemas";

export interface AIProvider {
  readonly name: "mock" | "openai";
  readonly model: string;
  extractRequirements(description: string): Promise<RequirementsDraft>;
  analyzeFit(input: FitInput): Promise<FitDraft>;
  applicationMaterials(input: MaterialsInput): Promise<MaterialsDraft>;
  interviewPrep(input: PrepInput): Promise<PrepDraft>;
}

export type AIErrorCode = "timeout" | "rate_limited" | "provider_error" | "malformed_response" | "not_configured";

export class AIError extends Error {
  constructor(
    readonly code: AIErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "AIError";
  }
}

export function userMessageForAIError(error: unknown): string {
  if (error instanceof AIError) {
    switch (error.code) {
      case "timeout":
        return "The AI provider took too long to respond. Please try again.";
      case "rate_limited":
        return error.message;
      case "malformed_response":
        return "The AI provider returned a response we could not validate, so nothing was saved. Please try again.";
      case "not_configured":
        return "AI is not configured. Set AI_PROVIDER=mock or configure an API key.";
      default:
        return "The AI provider returned an error. Please try again later.";
    }
  }
  return "Something went wrong while generating this. Please try again.";
}
