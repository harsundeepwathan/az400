import { createHash } from "node:crypto";
import Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import { analyzeMeal, detectMediaType, type MessagesClient, type Usage } from "./analyze.js";
import type { Pricing, Quotas } from "./config.js";
import { transaction, type Db } from "./db.js";
import { entitlement } from "./appStore.js";
import { HttpError, type Logger } from "./http.js";

/** Decoded image limit. The app sends ~1024 px JPEGs at 0.7 quality (~150–400 KB). */
export const MAX_IMAGE_BYTES = 3 * 1024 * 1024;
const CACHE_HOURS = 24;
/** Statuses that consume quota: successful scans and "no food" (still a paid call). */
const COUNTED = ["pending", "ok", "no_food"];

export interface MealScanDeps {
  db: Db;
  client: MessagesClient;
  quotas: Quotas;
  pricing: Pricing;
  model: string;
  log: Logger;
  now?: () => Date;
}

export interface ScanAllowance {
  tier: "free" | "pro";
  used: number;
  limit: number;
  remaining: number;
  window: "week" | "day";
  resets_at: string | null;
}

export function cost(usage: Usage, pricing: Pricing): number {
  const dollars =
    (usage.input_tokens * pricing.inputPerMTok +
      usage.output_tokens * pricing.outputPerMTok +
      usage.cache_read_input_tokens * pricing.cacheReadPerMTok +
      usage.cache_creation_input_tokens * pricing.cacheWritePerMTok) /
    1_000_000;
  return Math.round(dollars * 1e6) / 1e6;
}

/** Scans used in the current window. Free: rolling 7 days. Pro: rolling 24 hours (fair use). */
export async function allowance(db: Pick<Db, "query">, userId: string, quotas: Quotas, now: Date): Promise<ScanAllowance> {
  const { tier } = await entitlement(db as Db, userId, now);
  const windowMs = tier === "free" ? 7 * 86_400_000 : 86_400_000;
  const limit = tier === "free" ? quotas.freeScansPerWeek : quotas.proScansPerDay;
  const { rows } = await db.query<{ used: string; oldest: Date | null }>(
    `select count(*) as used, min(created_at) as oldest from ai_requests
     where user_id = $1 and kind = 'meal_scan' and status = any($2) and created_at > $3`,
    [userId, COUNTED, new Date(now.getTime() - windowMs)],
  );
  const used = Number(rows[0].used);
  const oldest = rows[0].oldest;
  return {
    tier,
    used,
    limit,
    remaining: Math.max(limit - used, 0),
    window: tier === "free" ? "week" : "day",
    resets_at: used >= limit && oldest ? new Date(oldest.getTime() + windowMs).toISOString() : null,
  };
}

const ScanRequest = z.object({ image: z.string().min(16).max(Math.ceil((MAX_IMAGE_BYTES * 4) / 3) + 4) });

export async function scanMeal(deps: MealScanDeps, userId: string, body: unknown) {
  const now = deps.now?.() ?? new Date();
  const parsed = ScanRequest.safeParse(body);
  if (!parsed.success) throw new HttpError(400, "invalid_request");
  const image = Buffer.from(parsed.data.image, "base64");
  if (image.length > MAX_IMAGE_BYTES) throw new HttpError(413, "image_too_large");
  const mediaType = detectMediaType(image);
  if (!mediaType) throw new HttpError(400, "unsupported_image");
  const digest = createHash("sha256").update(image).digest();

  // Same photo again within a day (retries, double taps): serve the stored
  // result for free instead of paying for a second call.
  const cached = await deps.db.query<{ scan_id: string; items: unknown; tier: string }>(
    `select m.id as scan_id, m.items, r.tier from ai_requests r join meal_scans m on m.request_id = r.id
     where r.user_id = $1 and r.image_sha256 = $2 and r.status = 'ok' and r.created_at > $3
     order by r.created_at desc limit 1`,
    [userId, digest, new Date(now.getTime() - CACHE_HOURS * 3_600_000)],
  );
  if (cached.rows[0]) {
    const hit = cached.rows[0];
    await deps.db.query(
      "insert into ai_requests (user_id, kind, status, tier, image_bytes, image_sha256, created_at) values ($1, 'meal_scan', 'cached', $2, $3, $4, $5)",
      [userId, hit.tier, image.length, digest, now],
    );
    return { scan_id: hit.scan_id, items: hit.items, cached: true, allowance: await allowance(deps.db, userId, deps.quotas, now) };
  }

  // Check limits and reserve a slot atomically. The per-user advisory lock
  // stops parallel requests from slipping past the quota together.
  const requestId = await transaction(deps.db, async (client) => {
    await client.query("select pg_advisory_xact_lock(hashtextextended($1, 0))", [userId]);
    const burst = await client.query<{ n: string }>(
      "select count(*) as n from ai_requests where user_id = $1 and kind = 'meal_scan' and status <> 'cached' and created_at > $2",
      [userId, new Date(now.getTime() - 60_000)],
    );
    if (Number(burst.rows[0].n) >= deps.quotas.scansPerMinute) {
      throw new HttpError(429, "rate_limited", { retry_after_seconds: 60 });
    }
    const current = await allowance(client, userId, deps.quotas, now);
    if (current.remaining <= 0) {
      throw current.tier === "free"
        ? new HttpError(402, "scan_quota_exceeded", { allowance: current })
        : new HttpError(429, "daily_scan_limit", { allowance: current });
    }
    const { rows } = await client.query<{ id: string }>(
      `insert into ai_requests (user_id, kind, status, tier, image_bytes, image_sha256, created_at)
       values ($1, 'meal_scan', 'pending', $2, $3, $4, $5) returning id`,
      [userId, current.tier, image.length, digest, now],
    );
    return rows[0].id;
  });

  const started = Date.now();
  try {
    const result = await analyzeMeal(deps.client, image.toString("base64"), mediaType, { model: deps.model });
    const dollars = cost(result.usage, deps.pricing);
    await deps.db.query(
      `update ai_requests set status = $2, model = $3, input_tokens = $4, output_tokens = $5,
         cache_read_tokens = $6, cache_write_tokens = $7, cost_usd = $8, latency_ms = $9
       where id = $1`,
      [
        requestId, result.status, result.model, result.usage.input_tokens, result.usage.output_tokens,
        result.usage.cache_read_input_tokens, result.usage.cache_creation_input_tokens, dollars, Date.now() - started,
      ],
    );
    let scanId: string | null = null;
    if (result.status === "ok") {
      const { rows } = await deps.db.query<{ id: string }>(
        "insert into meal_scans (request_id, user_id, items, created_at) values ($1, $2, $3, $4) returning id",
        [requestId, userId, JSON.stringify(result.items), now],
      );
      scanId = rows[0].id;
    }
    deps.log.info("meal_scan", { user_id: userId, status: result.status, model: result.model, cost_usd: dollars, ms: Date.now() - started });
    // An empty list maps to MealRecognitionError.noFoodDetected in the app.
    return { scan_id: scanId, items: result.items, cached: false, allowance: await allowance(deps.db, userId, deps.quotas, now) };
  } catch (error) {
    const code = error instanceof Anthropic.APIError ? `api_${error.status ?? "connection"}` : "analysis_failed";
    await deps.db.query("update ai_requests set status = 'error', error_code = $2, latency_ms = $3 where id = $1", [requestId, code, Date.now() - started]);
    deps.log.error("meal_scan_failed", { user_id: userId, code, message: error instanceof Error ? error.message : String(error) });
    if (error instanceof Anthropic.RateLimitError || error instanceof Anthropic.APIConnectionError) throw new HttpError(503, "busy");
    throw new HttpError(502, "analysis_failed");
  }
}

export const ScanCorrection = z.object({
  itemsDetected: z.number().int().min(0).max(50),
  itemsLogged: z.number().int().min(0).max(50),
  renamed: z.number().int().min(0).max(50),
  removed: z.number().int().min(0).max(50),
  added: z.number().int().min(0).max(50),
  portionsChanged: z.number().int().min(0).max(50),
  macrosEdited: z.number().int().min(0).max(50),
  estimatedCalories: z.number().min(0).max(20_000),
  loggedCalories: z.number().min(0).max(20_000),
});

export async function recordCorrection(db: Db, userId: string, scanId: string, body: unknown, now: Date) {
  const parsed = ScanCorrection.safeParse(body);
  if (!parsed.success || !z.uuid().safeParse(scanId).success) throw new HttpError(400, "invalid_request");
  const { rowCount } = await db.query(
    "update meal_scans set correction = $3, corrected_at = $4 where id = $1 and user_id = $2",
    [scanId, userId, JSON.stringify(parsed.data), now],
  );
  if (!rowCount) throw new HttpError(404, "not_found");
}
