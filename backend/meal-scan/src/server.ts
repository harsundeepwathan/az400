import Anthropic from "@anthropic-ai/sdk";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { analyzeMeal, detectMediaType, NoFoodError, RefusedError, type MessagesClient } from "./analyze.js";

const MAX_BODY_BYTES = 8 * 1024 * 1024; // ~6 MB of image after base64 overhead
const RATE_LIMIT = { windowMs: 60_000, max: 10 };

export interface ServerConfig {
  client: MessagesClient;
  /** Shared secret the app sends as `X-Vector-Key`. Use App Attest in production. */
  appKey: string;
}

export function createMealScanServer(config: ServerConfig) {
  const hits = new Map<string, number[]>();

  function rateLimited(ip: string): boolean {
    const now = Date.now();
    const recent = (hits.get(ip) ?? []).filter((t) => now - t < RATE_LIMIT.windowMs);
    recent.push(now);
    hits.set(ip, recent);
    return recent.length > RATE_LIMIT.max;
  }

  function send(res: ServerResponse, status: number, body: unknown) {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(body));
  }

  function authorized(req: IncomingMessage): boolean {
    const given = Buffer.from(String(req.headers["x-vector-key"] ?? ""));
    const expected = Buffer.from(config.appKey);
    return given.length === expected.length && timingSafeEqual(given, expected);
  }

  async function readBody(req: IncomingMessage): Promise<Buffer | null> {
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of req) {
      size += (chunk as Buffer).length;
      if (size > MAX_BODY_BYTES) return null;
      chunks.push(chunk as Buffer);
    }
    return Buffer.concat(chunks);
  }

  return createServer(async (req, res) => {
    if (req.method === "GET" && req.url === "/health") return send(res, 200, { ok: true });
    if (req.method !== "POST" || req.url !== "/v1/meal-scan") return send(res, 404, { error: "not_found" });
    if (!authorized(req)) return send(res, 401, { error: "unauthorized" });
    if (rateLimited(req.socket.remoteAddress ?? "unknown")) return send(res, 429, { error: "rate_limited" });

    const body = await readBody(req);
    if (!body) return send(res, 413, { error: "image_too_large" });

    let image: Buffer;
    try {
      const json = JSON.parse(body.toString("utf8")) as { image?: unknown };
      if (typeof json.image !== "string") throw new Error("missing image");
      image = Buffer.from(json.image, "base64");
    } catch {
      return send(res, 400, { error: "invalid_request" });
    }
    const mediaType = detectMediaType(image);
    if (!mediaType) return send(res, 400, { error: "unsupported_image" });

    try {
      const analysis = await analyzeMeal(config.client, image.toString("base64"), mediaType);
      return send(res, 200, { items: analysis.items });
    } catch (error) {
      // An empty list maps to MealRecognitionError.noFoodDetected in the app.
      if (error instanceof NoFoodError || error instanceof RefusedError) return send(res, 200, { items: [] });
      if (error instanceof Anthropic.RateLimitError) return send(res, 503, { error: "busy" });
      if (error instanceof Anthropic.APIConnectionError) return send(res, 503, { error: "upstream_unavailable" });
      if (error instanceof Anthropic.APIError) {
        console.error(`Claude API error ${error.status}: ${error.message}`);
        return send(res, 502, { error: "upstream_error" });
      }
      console.error("Meal scan failed:", error);
      return send(res, 502, { error: "analysis_failed" });
    }
  });
}

// Entry point: `ANTHROPIC_API_KEY=... VECTOR_APP_KEY=... npm start`
if (import.meta.url === `file://${process.argv[1]}`) {
  const appKey = process.env.VECTOR_APP_KEY;
  if (!appKey) throw new Error("Set VECTOR_APP_KEY to the shared secret configured in the app.");
  const port = Number(process.env.PORT ?? 8787);
  createMealScanServer({ client: new Anthropic(), appKey }).listen(port, () => {
    console.log(`Vector meal-scan listening on :${port}`);
  });
}
