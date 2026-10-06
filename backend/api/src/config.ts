/** Runtime configuration, read once from the environment. Nothing secret has a default. */
export interface Config {
  port: number;
  databaseUrl: string;
  /** HMAC key for access tokens; at least 32 bytes. */
  jwtSecret: Uint8Array;
  /** The iOS bundle id: the audience of Sign in with Apple tokens and StoreKit transactions. */
  bundleId: string;
  /** StoreKit product ids that unlock Pro. */
  proProductIds: Set<string>;
  /** Apple Root CA - G3 (DER or PEM) from apple.com/certificateauthority. Without it, purchases can't be verified. */
  appleRootCertificate?: Buffer;
  /** Allow Sandbox/Xcode transactions (development and TestFlight builds). */
  allowSandbox: boolean;
  quotas: Quotas;
  pricing: Pricing;
  model: string;
}

export interface Quotas {
  /** Scans per rolling 7 days on the free tier. Matches the in-app copy. */
  freeScansPerWeek: number;
  /** Fair-use ceiling on Pro, to bound cost from abuse or automation. */
  proScansPerDay: number;
  /** Burst limit for any user. */
  scansPerMinute: number;
}

/** US dollars per million tokens. Check against the current Claude price list. */
export interface Pricing {
  inputPerMTok: number;
  outputPerMTok: number;
  cacheReadPerMTok: number;
  cacheWritePerMTok: number;
}

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (!value) throw new Error(`Missing required environment variable ${name}`);
  return value;
}

function number(env: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const raw = env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0) throw new Error(`${name} must be a non-negative number`);
  return value;
}

export function loadConfig(env: NodeJS.ProcessEnv, readFile: (path: string) => Buffer): Config {
  const secret = required(env, "JWT_SECRET");
  if (Buffer.byteLength(secret) < 32) throw new Error("JWT_SECRET must be at least 32 bytes");
  const input = number(env, "PRICE_INPUT_PER_MTOK", 5);
  return {
    port: number(env, "PORT", 8787),
    databaseUrl: required(env, "DATABASE_URL"),
    jwtSecret: new TextEncoder().encode(secret),
    bundleId: required(env, "APP_BUNDLE_ID"),
    proProductIds: new Set(required(env, "PRO_PRODUCT_IDS").split(",").map((id) => id.trim()).filter(Boolean)),
    appleRootCertificate: env.APPLE_ROOT_CA_PATH ? readFile(env.APPLE_ROOT_CA_PATH) : undefined,
    allowSandbox: env.ALLOW_SANDBOX_PURCHASES === "true",
    quotas: {
      freeScansPerWeek: number(env, "FREE_SCANS_PER_WEEK", 3),
      proScansPerDay: number(env, "PRO_SCANS_PER_DAY", 30),
      scansPerMinute: number(env, "SCANS_PER_MINUTE", 4),
    },
    pricing: {
      inputPerMTok: input,
      outputPerMTok: number(env, "PRICE_OUTPUT_PER_MTOK", 25),
      cacheReadPerMTok: number(env, "PRICE_CACHE_READ_PER_MTOK", input * 0.1),
      cacheWritePerMTok: number(env, "PRICE_CACHE_WRITE_PER_MTOK", input * 1.25),
    },
    model: env.CLAUDE_MODEL ?? "claude-opus-5-5",
  };
}
