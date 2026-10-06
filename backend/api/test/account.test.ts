import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { JPEG, startApp, type TestApp } from "./helpers.js";

let app: TestApp;
before(async () => { app = await startApp(); });
after(async () => { await app.close(); });

const event = (name: string, properties: Record<string, unknown> = {}) => ({ id: randomUUID(), name, occurred_at: new Date().toISOString(), properties });

test("analytics batches are validated and idempotent", async () => {
  const { access_token, user_id } = await app.signIn();
  const batch = { app_version: "1.0 (12)", events: [event("workout_completed", { duration_min: 52, sets: 18 }), event("food_logged", { source: "search" })] };
  const first = await app.request("POST", "/v1/events", { token: access_token, body: batch });
  assert.equal(first.status, 202);
  assert.equal(first.json.stored, 2);
  const retry = await app.request("POST", "/v1/events", { token: access_token, body: batch });
  assert.equal(retry.json.stored, 0, "client retries don't duplicate events");

  assert.equal((await app.request("POST", "/v1/events", { token: access_token, body: { events: [event("anything_goes")] } })).status, 400);
  assert.equal((await app.request("POST", "/v1/events", { token: access_token, body: { events: [event("set_logged", { nested: { a: 1 } })] } })).status, 400);
  const { rows } = await app.db.query("select name, app_version from analytics_events where user_id = $1 order by name", [user_id]);
  assert.deepEqual(rows.map((r) => r.name), ["food_logged", "workout_completed"]);
  assert.equal(rows[0].app_version, "1.0 (12)");
});

test("opting out deletes stored analytics and stops collection", async () => {
  const { access_token, user_id } = await app.signIn();
  await app.request("POST", "/v1/events", { token: access_token, body: { events: [event("app_opened")] } });
  assert.equal((await app.request("PATCH", "/v1/me", { token: access_token, body: { analytics_opt_out: true } })).status, 204);
  const after = await app.request("POST", "/v1/events", { token: access_token, body: { events: [event("app_opened")] } });
  assert.equal(after.json.stored, 0);
  const { rows } = await app.db.query("select count(*)::int as n from analytics_events where user_id = $1", [user_id]);
  assert.equal(rows[0].n, 0);
});

test("deleting the account removes personal data and invalidates tokens", async () => {
  const { access_token, refresh_token, user_id } = await app.signIn();
  await app.request("POST", "/v1/meal-scan", { token: access_token, body: { image: JPEG.toString("base64") } });
  await app.request("POST", "/v1/events", { token: access_token, body: { events: [event("app_opened")] } });

  assert.equal((await app.request("DELETE", "/v1/me", { token: access_token })).status, 204);
  assert.equal((await app.request("GET", "/v1/me", { token: access_token })).status, 401, "access token dies with the account");
  assert.equal((await app.request("POST", "/v1/auth/refresh", { body: { refresh_token } })).status, 401);

  for (const table of ["users", "refresh_tokens", "meal_scans", "analytics_events", "subscriptions"]) {
    const column = table === "users" ? "id" : "user_id";
    const { rows } = await app.db.query(`select count(*)::int as n from ${table} where ${column} = $1`, [user_id]);
    assert.equal(rows[0].n, 0, `${table} is cleared`);
  }
  const { rows } = await app.db.query("select count(*)::int as n, sum(cost_usd)::float as cost from ai_requests where user_id is null");
  assert.equal(rows[0].n, 1, "cost history is kept without the user id");
  assert.ok(rows[0].cost > 0);
});

test("cost monitoring view", async () => {
  const { rows } = await app.db.query("select tier, scans, cost_usd from ai_daily_cost");
  assert.ok(rows.length >= 1);
  assert.ok(rows.every((r) => r.tier === "free"));
});
