import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { randomUUID } from "node:crypto";
import { CompactSign, createLocalJWKSet, exportJWK, generateKeyPair, importPKCS8, SignJWT } from "jose";
import type { MessagesClient } from "../src/analyze.js";
import { createApp } from "../src/app.js";
import { APPLE_ISSUER } from "../src/auth.js";
import type { Config } from "../src/config.js";
import { createPool, migrate, type Db } from "../src/db.js";
import { silentLogger } from "../src/http.js";

export const BUNDLE_ID = "app.vector.ios";
export const PRO_PRODUCT = "app.vector.pro.yearly";
export const JPEG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(64)]);

/** A fresh schema per test file, so tests run against real Postgres in isolation. */
export async function testDatabase(): Promise<{ db: Db; drop: () => Promise<void> }> {
  const url = process.env.TEST_DATABASE_URL ?? "postgres://vector:vector@localhost:5432/vector_test";
  const schema = "test_" + randomUUID().replaceAll("-", "");
  const admin = createPool(url, { max: 1 });
  await admin.query(`create schema ${schema}`);
  await admin.end();
  const db = createPool(url, { options: `-c search_path=${schema}` });
  await migrate(db, new URL("../../migrations", import.meta.url).pathname);
  return {
    db,
    drop: async () => {
      await db.query(`drop schema ${schema} cascade`);
      await db.end();
    },
  };
}

// MARK: Sign in with Apple

export async function appleSigner() {
  const { privateKey, publicKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), kid: "test-key", alg: "RS256" };
  return {
    keys: createLocalJWKSet({ keys: [jwk] }),
    async token(sub: string, options: { audience?: string; nonce?: string; expiresIn?: string } = {}) {
      const jwt = new SignJWT(options.nonce ? { nonce: options.nonce } : {})
        .setProtectedHeader({ alg: "RS256", kid: "test-key" })
        .setIssuer(APPLE_ISSUER)
        .setAudience(options.audience ?? BUNDLE_ID)
        .setSubject(sub)
        .setIssuedAt()
        .setExpirationTime(options.expiresIn ?? "10m");
      return jwt.sign(privateKey);
    },
  };
}

// MARK: Claude

export interface FakeClaude extends MessagesClient {
  calls: any[];
  /** The per-request options (timeout, maxRetries) passed with each call. */
  options: any[];
  reply: any;
}

export function fakeClaude(reply: any = plateReply()): FakeClaude {
  const fake: FakeClaude = {
    calls: [],
    options: [],
    reply,
    beta: {
      messages: {
        create: (async (request: any, options?: any) => {
          fake.calls.push(request);
          fake.options.push(options);
          // An array is a queue of replies, one per call (the last one repeats).
          const reply = Array.isArray(fake.reply) ? (fake.reply.length > 1 ? fake.reply.shift() : fake.reply[0]) : fake.reply;
          if (reply instanceof Error) throw reply;
          return reply;
        }) as any,
      },
    },
  };
  return fake;
}

export const plate = {
  no_food_detected: false,
  items: [
    { name: "Chicken breast, grilled", grams: 180, calories: 297, protein: 55.8, carbs: 0, fat: 6.5, confidence: 0.9,
      alternatives: ["Chicken thigh", "Turkey breast", "Tofu", "Pork loin"] },
    { name: "White rice", grams: 200, calories: 260, protein: 5.4, carbs: 56.4, fat: 0.6, confidence: 0.85, alternatives: [] },
  ],
};

export function plateReply(payload: object = plate, stop_reason = "end_turn") {
  return {
    model: "claude-opus-5-5",
    stop_reason,
    content: stop_reason === "refusal" ? [] : [{ type: "text", text: JSON.stringify(payload) }],
    usage: { input_tokens: 1800, output_tokens: 400, cache_read_input_tokens: 300, cache_creation_input_tokens: 0 },
  };
}

// MARK: StoreKit

/**
 * Builds a root → intermediate → leaf chain with OpenSSL, carrying the same
 * marker extensions as Apple's App Store certificates, and signs
 * transactions with the leaf key, exactly like StoreKit's JWS format.
 */
export function storeKitChain() {
  const dir = mkdtempSync(join(tmpdir(), "vector-storekit-"));
  const run = (...args: string[]) => execFileSync("openssl", args, { cwd: dir, stdio: "pipe" });
  const ext = (name: string, body: string) => writeFileSync(join(dir, name), body);
  run("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "root.key");
  run("req", "-x509", "-new", "-key", "root.key", "-subj", "/CN=Test Root CA G3", "-days", "3650", "-out", "root.pem",
      "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign");
  for (const [name, signer, oid, ca] of [["intermediate", "root", "1.2.840.113635.100.6.2.1", true], ["leaf", "intermediate", "1.2.840.113635.100.6.11.1", false]] as const) {
    run("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", `${name}.key`);
    run("req", "-new", "-key", `${name}.key`, "-subj", `/CN=Test ${name}`, "-out", `${name}.csr`);
    ext(`${name}.ext`, `basicConstraints=critical,CA:${ca ? "TRUE" : "FALSE"}\n${oid}=ASN1:NULL\n`);
    run("x509", "-req", "-in", `${name}.csr`, "-CA", `${signer}.pem`, "-CAkey", `${signer}.key`, "-CAcreateserial",
        "-days", "3650", "-extfile", `${name}.ext`, "-out", `${name}.pem`);
  }
  run("pkcs8", "-topk8", "-nocrypt", "-in", "leaf.key", "-out", "leaf.p8");
  const der = (name: string) => execFileSync("openssl", ["x509", "-in", `${name}.pem`, "-outform", "DER"], { cwd: dir });
  const chain = { root: der("root"), intermediate: der("intermediate"), leaf: der("leaf"), leafKey: readFileSync(join(dir, "leaf.p8"), "utf8") };
  rmSync(dir, { recursive: true, force: true });
  return {
    root: chain.root,
    async sign(payload: object, options: { x5c?: string[] } = {}) {
      const key = await importPKCS8(chain.leafKey, "ES256");
      const x5c = options.x5c ?? [chain.leaf, chain.intermediate, chain.root].map((b) => b.toString("base64"));
      return new CompactSign(new TextEncoder().encode(JSON.stringify(payload)))
        .setProtectedHeader({ alg: "ES256", x5c })
        .sign(key);
    },
  };
}

export function transactionPayload(overrides: Record<string, unknown> = {}) {
  const now = Date.now();
  return {
    transactionId: "2000000123",
    originalTransactionId: "2000000100",
    bundleId: BUNDLE_ID,
    productId: PRO_PRODUCT,
    purchaseDate: now - 86_400_000,
    expiresDate: now + 30 * 86_400_000,
    environment: "Production",
    type: "Auto-Renewable Subscription",
    signedDate: now,
    ...overrides,
  };
}

// MARK: App

export function testConfig(overrides: Partial<Config> = {}): Omit<Config, "port" | "databaseUrl"> {
  return {
    jwtSecret: new TextEncoder().encode("test-secret-test-secret-test-secret!"),
    bundleId: BUNDLE_ID,
    proProductIds: new Set([PRO_PRODUCT]),
    appleRootCertificate: undefined,
    allowSandbox: false,
    quotas: { freeScansPerWeek: 3, proScansPerDay: 30, scansPerMinute: 10 },
    pricing: { inputPerMTok: 5, outputPerMTok: 25, cacheReadPerMTok: 0.5, cacheWritePerMTok: 6.25 },
    model: "claude-opus-5-5",
    ...overrides,
  };
}

export interface TestApp {
  db: Db;
  claude: FakeClaude;
  apple: Awaited<ReturnType<typeof appleSigner>>;
  url: string;
  request(method: string, path: string, options?: { token?: string; body?: unknown }): Promise<{ status: number; json: any }>;
  signIn(sub?: string): Promise<{ access_token: string; refresh_token: string; user_id: string }>;
  close(): Promise<void>;
}

export async function startApp(config: Partial<Config> = {}, claude = fakeClaude()): Promise<TestApp> {
  const { db, drop } = await testDatabase();
  const apple = await appleSigner();
  const server = createApp({ config: testConfig(config), db, claude, appleKeys: apple.keys, log: silentLogger }).listen(0);
  await new Promise((resolve) => server.once("listening", resolve));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const app: TestApp = {
    db,
    claude,
    apple,
    url,
    async request(method, path, options = {}) {
      const headers: Record<string, string> = {};
      if (options.token) headers.Authorization = `Bearer ${options.token}`;
      if (options.body !== undefined) headers["Content-Type"] = "application/json";
      const res = await fetch(url + path, { method, headers, body: options.body === undefined ? undefined : JSON.stringify(options.body) });
      const text = await res.text();
      return { status: res.status, json: text ? JSON.parse(text) : undefined };
    },
    async signIn(sub = "apple-user-" + randomUUID()) {
      const { status, json } = await app.request("POST", "/v1/auth/apple", { body: { identity_token: await apple.token(sub) } });
      if (status !== 200) throw new Error(`sign in failed: ${status} ${JSON.stringify(json)}`);
      return json;
    },
    async close() {
      await new Promise((resolve) => server.close(resolve));
      await drop();
    },
  };
  return app;
}
