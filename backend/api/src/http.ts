import type { IncomingMessage, ServerResponse } from "node:http";
import { randomUUID } from "node:crypto";

export class HttpError extends Error {
  constructor(readonly status: number, readonly code: string, readonly details?: Record<string, unknown>) {
    super(code);
  }
}

export interface Request {
  id: string;
  method: string;
  path: string;
  params: Record<string, string>;
  headers: IncomingMessage["headers"];
  ip: string;
  raw: IncomingMessage;
  /** Set by `authenticate`, for request logs. */
  userId?: string;
}

export type Handler = (req: Request) => Promise<{ status: number; body?: unknown }>;

interface Route {
  method: string;
  pattern: RegExp;
  keys: string[];
  handler: Handler;
}

/** A tiny router: `/v1/meal-scans/:id/correction` style paths, JSON in and out. */
export class Router {
  private routes: Route[] = [];

  on(method: string, path: string, handler: Handler) {
    const keys: string[] = [];
    const pattern = new RegExp(
      "^" + path.replace(/:([a-zA-Z]+)/g, (_, key: string) => {
        keys.push(key);
        return "([^/]+)";
      }) + "$",
    );
    this.routes.push({ method, pattern, keys, handler });
    return this;
  }

  async handle(raw: IncomingMessage, res: ServerResponse, log: Logger) {
    const started = Date.now();
    const id = randomUUID();
    const path = (raw.url ?? "/").split("?")[0];
    const method = raw.method ?? "GET";
    let status = 500;
    let request: Request | undefined;
    try {
      const matches = this.routes.filter((route) => route.pattern.test(path));
      const route = matches.find((candidate) => candidate.method === method);
      if (!route) throw new HttpError(matches.length ? 405 : 404, matches.length ? "method_not_allowed" : "not_found");
      const values = route.pattern.exec(path)!.slice(1);
      const params = Object.fromEntries(route.keys.map((key, index) => [key, decodeURIComponent(values[index])]));
      const req: Request = { id, method, path, params, headers: raw.headers, ip: clientIp(raw), raw };
      request = req;
      const result = await route.handler(req);
      status = result.status;
      send(res, result.status, result.body, id);
    } catch (error) {
      if (error instanceof HttpError) {
        status = error.status;
        send(res, error.status, { error: error.code, ...error.details }, id);
      } else {
        status = 500;
        log.error("unhandled_error", { request_id: id, path, error: error instanceof Error ? error.message : String(error) });
        send(res, 500, { error: "internal_error" }, id);
      }
    } finally {
      // Never log bodies, tokens or images.
      log.info("request", { request_id: id, method, path, status, ms: Date.now() - started, user_id: request?.userId });
    }
  }
}

function send(res: ServerResponse, status: number, body: unknown, requestId: string) {
  if (res.headersSent) return;
  const headers: Record<string, string> = { "X-Request-Id": requestId, "Cache-Control": "no-store" };
  if (body === undefined) {
    res.writeHead(status, headers);
    res.end();
    return;
  }
  res.writeHead(status, { ...headers, "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

/**
 * Behind a load balancer, set TRUST_PROXY=true so the client address comes
 * from X-Forwarded-For. Each proxy appends the address it received the
 * request from, so only the rightmost TRUSTED_PROXY_HOPS entries (default 1:
 * one load balancer) were written by proxies we run; everything to their left
 * is client-controlled. The client address is the entry the outermost trusted
 * proxy added: the TRUSTED_PROXY_HOPS-th from the right.
 */
export function clientIp(raw: Pick<IncomingMessage, "headers" | "socket">, env: NodeJS.ProcessEnv = process.env): string {
  if (env.TRUST_PROXY === "true") {
    const header = raw.headers["x-forwarded-for"];
    const entries = (Array.isArray(header) ? header.join(",") : String(header ?? ""))
      .split(",")
      .map((entry) => entry.trim())
      .filter(Boolean);
    const hops = Number(env.TRUSTED_PROXY_HOPS ?? 1);
    const trusted = Number.isInteger(hops) && hops >= 1 ? hops : 1;
    // Fewer entries than trusted hops: the leftmost is still proxy-written.
    if (entries.length) return entries[Math.max(0, entries.length - trusted)];
  }
  return raw.socket.remoteAddress ?? "unknown";
}

export async function readJson(req: Request, maxBytes: number): Promise<unknown> {
  const type = String(req.headers["content-type"] ?? "");
  if (!type.startsWith("application/json")) throw new HttpError(415, "unsupported_media_type");
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req.raw) {
    size += (chunk as Buffer).length;
    if (size > maxBytes) throw new HttpError(413, "payload_too_large");
    chunks.push(chunk as Buffer);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new HttpError(400, "invalid_json");
  }
}

export interface Logger {
  info(event: string, fields?: Record<string, unknown>): void;
  error(event: string, fields?: Record<string, unknown>): void;
}

/** One JSON object per line, for whatever log drain the host provides. */
export const jsonLogger: Logger = {
  info: (event, fields) => console.log(JSON.stringify({ level: "info", event, time: new Date().toISOString(), ...fields })),
  error: (event, fields) => console.error(JSON.stringify({ level: "error", event, time: new Date().toISOString(), ...fields })),
};

export const silentLogger: Logger = { info: () => {}, error: () => {} };

/**
 * Fixed-window limiter for unauthenticated endpoints (per instance). Memory
 * is hard-capped at `maxKeys` addresses: when full, expired windows are
 * pruned, and if it is still full a new address is rejected with 429 rather
 * than growing the map (addresses already tracked keep working).
 */
export class IpRateLimiter {
  private hits = new Map<string, { windowStart: number; count: number }>();
  private prunedAt = -Infinity;

  constructor(private readonly max: number, private readonly windowMs: number, private readonly maxKeys = 50_000) {}

  get size() {
    return this.hits.size;
  }

  check(key: string, now = Date.now()) {
    const entry = this.hits.get(key);
    if (!entry || now - entry.windowStart >= this.windowMs) {
      if (!entry && this.hits.size >= this.maxKeys) {
        // A full prune is O(maxKeys): at most once a second, so a flood of new addresses can't make every request pay for it.
        if (now - this.prunedAt >= 1000) this.prune(now);
        if (this.hits.size >= this.maxKeys) throw new HttpError(429, "rate_limited", { retry_after_seconds: Math.ceil(this.windowMs / 1000) });
      }
      this.hits.set(key, { windowStart: now, count: 1 });
      return;
    }
    entry.count += 1;
    if (entry.count > this.max) throw new HttpError(429, "rate_limited", { retry_after_seconds: Math.ceil((entry.windowStart + this.windowMs - now) / 1000) });
  }

  private prune(now: number) {
    this.prunedAt = now;
    for (const [key, entry] of this.hits) if (now - entry.windowStart >= this.windowMs) this.hits.delete(key);
  }
}
