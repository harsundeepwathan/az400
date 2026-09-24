import { z } from "zod";
import type { FitDraft, FitInput } from "../fit/types";
import { fitDraftSchema } from "../fit/types";
import { PROMPT_VERSIONS, SYSTEM_PREAMBLE, TASK_PROMPTS, untrusted } from "./prompts";
import { AIError, type AIProvider } from "./provider";
import {
  materialsDraftSchema,
  prepDraftSchema,
  requirementsDraftSchema,
  type MaterialsDraft,
  type MaterialsInput,
  type PrepDraft,
  type PrepInput,
  type RequirementsDraft,
} from "./schemas";

export type OpenAIConfig = {
  baseUrl: string;
  apiKey: string;
  model: string;
  jsonMode: "json_schema" | "json_object";
  timeoutMs: number;
  maxRetries: number;
  fetchImpl?: typeof fetch;
};

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Metadata-only logging. Never logs prompts, resume text or responses. */
function logCall(fields: Record<string, string | number | boolean>) {
  if (process.env.NODE_ENV !== "test") console.info(JSON.stringify({ event: "ai_call", ...fields }));
}

/**
 * OpenAI-compatible Chat Completions provider with structured JSON output,
 * timeouts, retries with exponential backoff and Zod validation.
 */
export class OpenAICompatibleProvider implements AIProvider {
  readonly name = "openai" as const;
  readonly model: string;

  constructor(private readonly config: OpenAIConfig) {
    this.model = config.model;
  }

  async call<T>(operation: string, schema: z.ZodType<T>, task: string, userContent: string): Promise<T> {
    const doFetch = this.config.fetchImpl ?? fetch;
    const responseFormat =
      this.config.jsonMode === "json_schema"
        ? { type: "json_schema", json_schema: { name: operation.replace(/[^a-zA-Z0-9_-]/g, "_"), schema: z.toJSONSchema(schema), strict: false } }
        : { type: "json_object" };

    let lastError: AIError = new AIError("provider_error", "AI request failed");
    for (let attempt = 0; attempt <= this.config.maxRetries; attempt++) {
      if (attempt > 0) await sleep(Math.min(8000, 500 * 2 ** (attempt - 1)));
      const started = Date.now();
      let response: Response;
      try {
        response = await doFetch(`${this.config.baseUrl.replace(/\/$/, "")}/chat/completions`, {
          method: "POST",
          headers: { "content-type": "application/json", authorization: `Bearer ${this.config.apiKey}` },
          body: JSON.stringify({
            model: this.config.model,
            temperature: 0.2,
            response_format: responseFormat,
            messages: [
              { role: "system", content: `${SYSTEM_PREAMBLE}\n\nTask:\n${task}` },
              { role: "user", content: userContent },
            ],
          }),
          signal: AbortSignal.timeout(this.config.timeoutMs),
        });
      } catch (error) {
        const timedOut = error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError");
        lastError = new AIError(timedOut ? "timeout" : "provider_error", timedOut ? "AI request timed out" : "AI request failed");
        logCall({ operation, attempt, outcome: lastError.code, ms: Date.now() - started });
        continue;
      }

      logCall({ operation, attempt, status: response.status, ms: Date.now() - started });
      if (response.status === 429 || response.status >= 500) {
        lastError = new AIError(response.status === 429 ? "rate_limited" : "provider_error", "The AI provider is busy. Please try again shortly.");
        continue;
      }
      if (!response.ok) throw new AIError("provider_error", `AI provider rejected the request (${response.status})`);

      try {
        const body = (await response.json()) as { choices?: Array<{ message?: { content?: string } }> };
        const content = body.choices?.[0]?.message?.content ?? "";
        const parsed = schema.safeParse(JSON.parse(content));
        if (parsed.success) return parsed.data;
        lastError = new AIError("malformed_response", "AI response failed validation");
      } catch {
        lastError = new AIError("malformed_response", "AI response was not valid JSON");
      }
      logCall({ operation, attempt, outcome: "malformed_response" });
    }
    throw lastError;
  }

  extractRequirements(description: string): Promise<RequirementsDraft> {
    return this.call(PROMPT_VERSIONS.requirements, requirementsDraftSchema, TASK_PROMPTS.requirements, untrusted("job_description", description));
  }

  analyzeFit(input: FitInput): Promise<FitDraft> {
    const payload = [
      untrusted("job_description", `Title: ${input.job.title}\nCompany: ${input.job.company}\nLocation: ${input.job.location} (${input.job.workplace_type})\n\n${input.job.description}`),
      untrusted("requirements", JSON.stringify(input.job.requirements)),
      untrusted("candidate_preferences", JSON.stringify(input.profile)),
      untrusted("source_catalogue", JSON.stringify(input.sources.map((s) => ({ id: s.id, type: s.type, label: s.label, text: s.text, verified: s.verified })))),
    ].join("\n\n");
    return this.call(PROMPT_VERSIONS.fit, fitDraftSchema, TASK_PROMPTS.fit, payload);
  }

  applicationMaterials(input: MaterialsInput): Promise<MaterialsDraft> {
    const payload = [
      untrusted("job_description", `Title: ${input.job.title}\nCompany: ${input.job.company}\n\n${input.job.description}`),
      untrusted("candidate", JSON.stringify(input.profile)),
      untrusted("supported_requirements", JSON.stringify(input.supported)),
      untrusted("gaps", JSON.stringify(input.gaps)),
      untrusted("bullets", JSON.stringify(input.bullets)),
      untrusted("source_catalogue", JSON.stringify(input.sources.map((s) => ({ id: s.id, type: s.type, label: s.label, text: s.text })))),
    ].join("\n\n");
    return this.call(PROMPT_VERSIONS.materials, materialsDraftSchema, TASK_PROMPTS.materials, payload);
  }

  interviewPrep(input: PrepInput): Promise<PrepDraft> {
    const payload = [
      untrusted("job_description", `Title: ${input.job.title}\nCompany: ${input.job.company}\n\n${input.job.description}`),
      untrusted("requirements", JSON.stringify(input.job.requirements)),
      untrusted("supported_requirements", JSON.stringify(input.supported)),
      untrusted("gaps", JSON.stringify(input.gaps)),
      untrusted("evidence_items", JSON.stringify(input.evidence)),
      untrusted("interview_kind", input.interview_kind ?? "unknown"),
    ].join("\n\n");
    return this.call(PROMPT_VERSIONS.prep, prepDraftSchema, TASK_PROMPTS.prep, payload);
  }
}
