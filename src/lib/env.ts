import "server-only";
import { z } from "zod";

const schema = z.object({
  NODE_ENV: z.enum(["development", "production", "test"]).default("development"),
  APP_URL: z.string().url().default("http://localhost:3000"),
  AUTH_MODE: z.enum(["local", "supabase"]).default("local"),
  DATABASE_URL: z.string().min(1, "DATABASE_URL is required"),
  SESSION_SECRET: z.string().optional(),
  NEXT_PUBLIC_SUPABASE_URL: z.string().optional(),
  NEXT_PUBLIC_SUPABASE_ANON_KEY: z.string().optional(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().optional(),
  STORAGE_MODE: z.enum(["local", "supabase", ""]).optional(),
  AI_PROVIDER: z.enum(["mock", "openai"]).default("mock"),
  AI_BASE_URL: z.string().url().default("https://api.openai.com/v1"),
  AI_API_KEY: z.string().optional(),
  AI_MODEL: z.string().optional(),
  AI_JSON_MODE: z.enum(["json_schema", "json_object"]).default("json_schema"),
  AI_TIMEOUT_MS: z.coerce.number().int().min(1000).max(300000).default(45000),
  AI_MAX_RETRIES: z.coerce.number().int().min(0).max(5).default(2),
  AI_RATE_LIMIT_PER_HOUR: z.coerce.number().int().min(1).max(10000).default(60),
});

export type ServerEnv = z.infer<typeof schema> & { storageMode: "local" | "supabase" };

let cached: ServerEnv | undefined;

/** Validated server configuration. Throws a descriptive error on misconfiguration. */
export function env(): ServerEnv {
  if (cached) return cached;
  const parsed = schema.safeParse(process.env);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ");
    throw new Error(`Invalid configuration: ${issues}`);
  }
  const e = parsed.data;
  if (e.AUTH_MODE === "local" && (!e.SESSION_SECRET || e.SESSION_SECRET.length < 32)) {
    throw new Error("SESSION_SECRET must be set to at least 32 characters when AUTH_MODE=local.");
  }
  if (e.AUTH_MODE === "supabase" && (!e.NEXT_PUBLIC_SUPABASE_URL || !e.NEXT_PUBLIC_SUPABASE_ANON_KEY)) {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY are required when AUTH_MODE=supabase.");
  }
  if (e.AI_PROVIDER === "openai" && (!e.AI_API_KEY || !e.AI_MODEL)) {
    throw new Error("AI_API_KEY and AI_MODEL are required when AI_PROVIDER=openai.");
  }
  cached = { ...e, storageMode: e.STORAGE_MODE ? e.STORAGE_MODE : e.AUTH_MODE };
  return cached;
}
