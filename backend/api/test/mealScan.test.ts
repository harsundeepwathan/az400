import { after, before, beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import Anthropic from "@anthropic-ai/sdk";
import { fakeClaude, JPEG, plateReply, startApp, type TestApp } from "./helpers.js";
import { cost } from "../src/mealScan.js";

let app: TestApp;
before(async () => { app = await startApp(); });
after(async () => { await app.close(); });
beforeEach(() => { app.claude.reply = plateReply(); app.claude.calls.length = 0; });

let imageCounter = 0;
/** A distinct valid JPEG each call, so the result cache doesn't kick in. */
const image = () => {
  const bytes = Buffer.from(JPEG);
  bytes.writeUInt32BE(++imageCounter, 10);
  return bytes.toString("base64");
};

test("scans return the app's contract, log usage and cost, and store no image", async () => {
  const { access_token, user_id } = await app.signIn();
  const res = await app.request("POST", "/v1/meal-scan", { token: access_token, body: { image: image() } });
  assert.equal(res.status, 200);
  assert.equal(res.json.items.length, 2);
  assert.equal(res.json.items[0].alternatives.length, 3, "alternatives are capped at 3");
  assert.ok(res.json.scan_id);
  assert.equal(res.json.allowance.remaining, 2);

  const request = app.claude.calls[0];
  assert.equal(request.model, "claude-opus-5-5");
  assert.equal(request.fallbacks, "default");
  assert.deepEqual(request.betas, ["server-side-fallback-2026-07-01"]);
  assert.equal(request.output_config.format.type, "json_schema");
  assert.deepEqual(app.claude.options[0], { timeout: 45_000, maxRetries: 0 }, "no hidden SDK retries");

  const { rows } = await app.db.query("select * from ai_requests where user_id = $1", [user_id]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].status, "ok");
  assert.equal(rows[0].input_tokens, 1800);
  assert.equal(rows[0].output_tokens, 400);
  // 1800 × $5 + 400 × $25 + 300 × $0.50 per million tokens
  assert.equal(Number(rows[0].cost_usd), 0.01915);
  const columns = Object.keys(rows[0]);
  assert.ok(!columns.some((c) => c === "image" || c === "image_data"), "images are never stored");
});

test("free tier: three scans a week, then 402 with when it resets", async () => {
  const { access_token } = await app.signIn();
  for (let i = 0; i < 3; i++) {
    assert.equal((await app.request("POST", "/v1/meal-scan", { token: access_token, body: { image: image() } })).status, 200);
  }
  const blocked = await app.request("POST", "/v1/meal-scan", { token: access_token, body: { image: image() } });
  assert.equal(blocked.status, 402);
  assert.equal(blocked.json.error, "scan_quota_exceeded");
  assert.equal(blocked.json.allowance.remaining, 0);
  assert.ok(Date.parse(blocked.json.allowance.resets_at) > Date.now());
  assert.equal(app.claude.calls.length, 3, "no AI call once the quota is used");
});

test("parallel requests can't bypass the quota", async () => {
  const { access_token } = await app.signIn();
  const results = await Promise.all(
    Array.from({ length: 6 }, () => app.request("POST", "/v1/meal-scan", { token: access_token, body: { image: image() } })),
  );
  assert.equal(results.filter((r) => r.status === 200).length, 3);
  assert.equal(results.filter((r) => r.status === 402).length, 3);
});

test("the same photo within a day is served from cache for free", async () => {
  const { access_token, user_id } = await app.signIn();
  const photo = image();
  const first = await app.request("POST", "/v1/meal-scan", { token: access_token, body: { image: photo } });
  const second = await app.request("POST", "/v1/meal-scan", { token: access_token, body: { image: photo } });
  assert.equal(second.status, 200);
  assert.equal(second.json.cached, true);
  assert.equal(second.json.scan_id, first.json.scan_id);
  assert.equal(app.claude.calls.length, 1);
  assert.equal(second.json.allowance.used, 1, "a cache hit doesn't use quota");
  const { rows } = await app.db.query("select status, cost_usd from ai_requests where user_id = $1 order by created_at", [user_id]);
  assert.deepEqual(rows.map((r) => r.status).sort(), ["cached", "ok"]);
});

test("no food: empty items, recorded, counts as a scan; errors don't", async () => {
  const { access_token, user_id } = await app.signIn();
  app.claude.reply = plateReply({ no_food_detected: true, items: [] });
  const empty = await app.request("POST", "/v1/meal-scan", { token: access_token, body: { image: image() } });
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.json.items, []);
  assert.equal(empty.json.scan_id, null);

  app.claude.reply = new Anthropic.APIError(500, { type: "error" }, "boom", new Headers());
  const failed = await app.request("POST", "/v1/meal-scan", { token: access_token, body: { image: image() } });
  assert.equal(failed.status, 502);

  app.claude.reply = plateReply({}, "refusal");
  const refused = await app.request("POST", "/v1/meal-scan", { token: access_token, body: { image: image() } });
  assert.deepEqual(refused.json.items, []);

  const me = await app.request("GET", "/v1/me", { token: access_token });
  assert.equal(me.json.scans.used, 1, "only the no-food scan counts; errors and refusals don't");
  const { rows } = await app.db.query("select status, error_code from ai_requests where user_id = $1 order by created_at", [user_id]);
  assert.deepEqual(rows.map((r) => r.status), ["no_food", "error", "refused"]);
  assert.equal(rows[1].error_code, "api_500");
});

test("invalid input is rejected before any AI call", async () => {
  const { access_token } = await app.signIn();
  const notImage = Buffer.alloc(64, 7).toString("base64");
  assert.equal((await app.request("POST", "/v1/meal-scan", { token: access_token, body: { image: notImage } })).status, 400);
  assert.equal((await app.request("POST", "/v1/meal-scan", { token: access_token, body: { picture: "x" } })).status, 400);
  assert.equal((await app.request("POST", "/v1/meal-scan", { body: { image: image() } })).status, 401);
  assert.equal(app.claude.calls.length, 0);
});

test("burst limit per user", async () => {
  const limited = await startApp({ quotas: { freeScansPerWeek: 100, proScansPerDay: 100, scansPerMinute: 2 } }, fakeClaude());
  try {
    const { access_token } = await limited.signIn();
    const statuses = [];
    for (let i = 0; i < 3; i++) {
      statuses.push((await limited.request("POST", "/v1/meal-scan", { token: access_token, body: { image: image() } })).status);
    }
    assert.deepEqual(statuses, [200, 200, 429]);
  } finally {
    await limited.close();
  }
});

test("corrections are stored against the user's own scan only", async () => {
  const owner = await app.signIn();
  const other = await app.signIn();
  const scan = await app.request("POST", "/v1/meal-scan", { token: owner.access_token, body: { image: image() } });
  const correction = { itemsDetected: 2, itemsLogged: 2, renamed: 1, removed: 0, added: 0, portionsChanged: 1, macrosEdited: 0, estimatedCalories: 557, loggedCalories: 480 };
  const path = `/v1/meal-scans/${scan.json.scan_id}/correction`;
  assert.equal((await app.request("POST", path, { token: other.access_token, body: correction })).status, 404);
  assert.equal((await app.request("POST", path, { token: owner.access_token, body: { renamed: -1 } })).status, 400);
  assert.equal((await app.request("POST", path, { token: owner.access_token, body: correction })).status, 204);
  const { rows } = await app.db.query("select correction from meal_scans where id = $1", [scan.json.scan_id]);
  assert.equal(rows[0].correction.renamed, 1);
});

test("cost per million tokens", () => {
  const pricing = { inputPerMTok: 5, outputPerMTok: 25, cacheReadPerMTok: 0.5, cacheWritePerMTok: 6.25 };
  assert.equal(cost({ input_tokens: 1_000_000, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }, pricing), 5);
  assert.equal(cost({ input_tokens: 0, output_tokens: 1000, cache_read_input_tokens: 0, cache_creation_input_tokens: 1000 }, pricing), 0.03125);
});
