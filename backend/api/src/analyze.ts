import Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";

/** Response contract consumed by `RemoteMealRecognizer` in VectorCore. */
export const MealItem = z.object({
  name: z.string().min(1),
  grams: z.number().positive(),
  calories: z.number().min(0),
  protein: z.number().min(0),
  carbs: z.number().min(0),
  fat: z.number().min(0),
  confidence: z.number().min(0).max(1),
  alternatives: z.array(z.string()),
});
export const MealAnalysis = z.object({
  no_food_detected: z.boolean(),
  items: z.array(MealItem),
});
export type MealAnalysis = z.infer<typeof MealAnalysis>;

// JSON schema for structured outputs (mirrors the zod schema above).
const ITEM_SCHEMA = {
  type: "object",
  properties: {
    name: { type: "string", description: "Common food name, e.g. 'Chicken breast, grilled'" },
    grams: { type: "number", description: "Estimated edible weight on the plate in grams" },
    calories: { type: "number", description: "kcal for this portion" },
    protein: { type: "number", description: "grams of protein for this portion" },
    carbs: { type: "number", description: "grams of carbohydrate for this portion" },
    fat: { type: "number", description: "grams of fat for this portion" },
    confidence: { type: "number", description: "0-1 confidence in the identification (not the portion)" },
    alternatives: { type: "array", items: { type: "string" }, description: "Up to 3 other plausible identifications" },
  },
  required: ["name", "grams", "calories", "protein", "carbs", "fat", "confidence", "alternatives"],
  additionalProperties: false,
} as const;

const OUTPUT_SCHEMA = {
  type: "object",
  properties: {
    no_food_detected: { type: "boolean" },
    items: { type: "array", items: ITEM_SCHEMA },
  },
  required: ["no_food_detected", "items"],
  additionalProperties: false,
} as const;

// Kept byte-stable so it can be prompt-cached across requests.
const SYSTEM_PROMPT = `You estimate the nutrition of a meal from a single photo for a calorie-tracking app.

List each distinct food or drink you can see as its own item (separate the protein, the starch, vegetables, sauces and visible oils). For each item, estimate the edible weight in grams from visual cues such as plate size, utensils and typical serving sizes, then give calories and macros for that weight using standard nutrition references.

Be honest about uncertainty: set confidence below 0.6 when the identification is a guess, and offer up to three alternatives a user might pick instead. Include cooking fats and sauces when they are visible, because they are the most commonly missed calories. Do not invent foods you cannot see.

If the photo does not show food, set no_food_detected to true and return an empty items list.`;

export type ImageMediaType = "image/jpeg" | "image/png" | "image/webp" | "image/gif";

/** Token usage as reported by the API; the basis for cost tracking. */
export interface Usage {
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  cache_creation_input_tokens: number;
}

export type AnalyzeResult =
  | { status: "ok"; items: MealAnalysis["items"]; model: string; usage: Usage }
  | { status: "no_food" | "refused"; items: []; model: string; usage: Usage };

/** Minimal surface of the SDK the analyzer uses, so tests can inject a fake. */
export interface MessagesClient {
  beta: { messages: { create: Anthropic["beta"]["messages"]["create"] } };
}

export interface AnalyzeOptions {
  model?: string;
  effort?: "low" | "medium" | "high";
}

export async function analyzeMeal(
  client: MessagesClient,
  imageBase64: string,
  mediaType: ImageMediaType,
  options: AnalyzeOptions = {},
): Promise<AnalyzeResult> {
  const response = await client.beta.messages.create({
    model: options.model ?? "claude-opus-5-5",
    max_tokens: 16000,
    // Server-side fallback keeps a classifier false positive from failing the scan.
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    // The user is waiting on a camera screen; low effort keeps latency down.
    // Raise to "medium" if portion accuracy measurably improves on your eval set.
    output_config: {
      effort: options.effort ?? "low",
      format: { type: "json_schema", schema: OUTPUT_SCHEMA },
    },
    system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
    messages: [
      {
        role: "user",
        content: [
          { type: "image", source: { type: "base64", media_type: mediaType, data: imageBase64 } },
          { type: "text", text: "Identify the foods in this meal and estimate each portion." },
        ],
      },
    ],
  }, { timeout: 45_000 });

  const usage: Usage = {
    input_tokens: response.usage?.input_tokens ?? 0,
    output_tokens: response.usage?.output_tokens ?? 0,
    cache_read_input_tokens: response.usage?.cache_read_input_tokens ?? 0,
    cache_creation_input_tokens: response.usage?.cache_creation_input_tokens ?? 0,
  };
  // With server-side fallback the serving model can differ from the requested one.
  const model = response.model;
  if (response.stop_reason === "refusal") return { status: "refused", items: [], model, usage };

  const text = response.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("");
  const parsed = MealAnalysis.parse(JSON.parse(text));
  const items = parsed.items
    .filter((item) => item.grams > 0)
    .map((item) => ({ ...item, alternatives: item.alternatives.slice(0, 3) }));
  if (parsed.no_food_detected || items.length === 0) return { status: "no_food", items: [], model, usage };
  return { status: "ok", items, model, usage };
}

/** Detects the image type from its magic bytes; the app always sends JPEG today. */
export function detectMediaType(bytes: Buffer): ImageMediaType | null {
  if (bytes.length < 12) return null;
  if (bytes[0] === 0xff && bytes[1] === 0xd8) return "image/jpeg";
  if (bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
  if (bytes.subarray(0, 4).toString("ascii") === "RIFF" && bytes.subarray(8, 12).toString("ascii") === "WEBP") return "image/webp";
  if (bytes.subarray(0, 3).toString("ascii") === "GIF") return "image/gif";
  return null;
}
