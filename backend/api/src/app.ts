import { createServer } from "node:http";
import type { JWTVerifyGetKey } from "jose";
import { z } from "zod";
import type { MessagesClient } from "./analyze.js";
import { recordTransaction, entitlement } from "./appStore.js";
import { authenticate, refreshSession, signInWithApple, signOut } from "./auth.js";
import type { Config } from "./config.js";
import type { Db } from "./db.js";
import { ingestEvents } from "./events.js";
import { HttpError, IpRateLimiter, readJson, Router, type Logger } from "./http.js";
import { allowance, MAX_IMAGE_BYTES, recordCorrection, scanMeal } from "./mealScan.js";

export interface AppDeps {
  config: Omit<Config, "port" | "databaseUrl">;
  db: Db;
  claude: MessagesClient;
  appleKeys: JWTVerifyGetKey;
  log: Logger;
  now?: () => Date;
}

const SignIn = z.object({ identity_token: z.string().min(1).max(8192), nonce: z.string().min(1).max(256).optional() });
const Refresh = z.object({ refresh_token: z.string().min(16).max(256) });
const Purchase = z.object({ signed_transaction: z.string().min(1).max(32_768) });
const Preferences = z.object({ analytics_opt_out: z.boolean() });

function parse<T>(schema: z.ZodType<T>, body: unknown): T {
  const result = schema.safeParse(body);
  if (!result.success) throw new HttpError(400, "invalid_request");
  return result.data;
}

export function createApp(deps: AppDeps) {
  const { config, db, log } = deps;
  const now = () => deps.now?.() ?? new Date();
  const auth = { db, jwtSecret: config.jwtSecret, bundleId: config.bundleId, appleKeys: deps.appleKeys, now: deps.now };
  const authLimiter = new IpRateLimiter(20, 60_000);
  const user = (req: Parameters<typeof authenticate>[1]) => authenticate(auth, req);

  const router = new Router()
    .on("GET", "/health", async () => {
      await db.query("select 1");
      return { status: 200, body: { ok: true } };
    })

    // Auth
    .on("POST", "/v1/auth/apple", async (req) => {
      authLimiter.check(req.ip);
      const body = parse(SignIn, await readJson(req, 16_384));
      return { status: 200, body: await signInWithApple(auth, body.identity_token, body.nonce) };
    })
    .on("POST", "/v1/auth/refresh", async (req) => {
      authLimiter.check(req.ip);
      const body = parse(Refresh, await readJson(req, 4096));
      return { status: 200, body: await refreshSession(auth, body.refresh_token) };
    })
    .on("POST", "/v1/auth/sign-out", async (req) => {
      await signOut(db, await user(req));
      return { status: 204 };
    })

    // Account
    .on("GET", "/v1/me", async (req) => {
      const userId = await user(req);
      const { rows } = await db.query<{ analytics_opt_out: boolean; created_at: Date }>(
        "select analytics_opt_out, created_at from users where id = $1",
        [userId],
      );
      return {
        status: 200,
        body: {
          user_id: userId,
          created_at: rows[0].created_at.toISOString(),
          analytics_opt_out: rows[0].analytics_opt_out,
          entitlement: await entitlement(db, userId, now()),
          scans: await allowance(db, userId, config.quotas, now()),
        },
      };
    })
    .on("PATCH", "/v1/me", async (req) => {
      const userId = await user(req);
      const body = parse(Preferences, await readJson(req, 1024));
      await db.query("update users set analytics_opt_out = $2 where id = $1", [userId, body.analytics_opt_out]);
      if (body.analytics_opt_out) await db.query("delete from analytics_events where user_id = $1", [userId]);
      return { status: 204 };
    })
    .on("DELETE", "/v1/me", async (req) => {
      const userId = await user(req);
      // Cascades to tokens, subscriptions, scans, corrections and analytics.
      // AI cost rows are kept with the user id cleared, for cost reporting.
      await db.query("delete from users where id = $1", [userId]);
      log.info("account_deleted", { user_id: userId });
      return { status: 204 };
    })

    // Subscriptions
    .on("POST", "/v1/subscription/transactions", async (req) => {
      const userId = await user(req);
      const body = parse(Purchase, await readJson(req, 65_536));
      const result = await recordTransaction(
        { db, bundleId: config.bundleId, proProductIds: config.proProductIds, rootCertificate: config.appleRootCertificate, allowSandbox: config.allowSandbox, now: deps.now },
        userId,
        body.signed_transaction,
      );
      return { status: 200, body: result };
    })

    // AI meal scan
    .on("POST", "/v1/meal-scan", async (req) => {
      const userId = await user(req);
      const body = await readJson(req, Math.ceil((MAX_IMAGE_BYTES * 4) / 3) + 1024);
      const result = await scanMeal(
        { db, client: deps.claude, quotas: config.quotas, pricing: config.pricing, model: config.model, log, now: deps.now },
        userId,
        body,
      );
      return { status: 200, body: result };
    })
    .on("POST", "/v1/meal-scans/:id/correction", async (req) => {
      const userId = await user(req);
      await recordCorrection(db, userId, req.params.id, await readJson(req, 4096), now());
      return { status: 204 };
    })

    // Analytics
    .on("POST", "/v1/events", async (req) => {
      const userId = await user(req);
      const result = await ingestEvents(db, userId, await readJson(req, 128 * 1024), now());
      return { status: 202, body: result };
    });

  return createServer((req, res) => {
    void router.handle(req, res, log);
  });
}
