import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { testDatabase } from "./helpers.js";
import type { Db } from "../src/db.js";

let db: Db;
let drop: () => Promise<void>;
const users: Record<string, string> = {};

before(async () => {
  ({ db, drop } = await testDatabase());
  // u1 Pro and active, u2 free and active, u3 / u4 free and inactive (last seen 60 days ago).
  for (const [name, lastSeen] of [["u1", "1 day"], ["u2", "2 days"], ["u3", "60 days"], ["u4", "60 days"]]) {
    const { rows } = await db.query("insert into users (apple_sub, last_seen_at) values ($1, now() - $2::interval) returning id", [name, lastSeen]);
    users[name] = rows[0].id;
  }
  await db.query(
    `insert into subscriptions (original_transaction_id, user_id, product_id, environment, purchased_at, expires_at)
     values ('cv-1', $1, 'pro', 'Production', now() - interval '10 days', now() + interval '20 days')`,
    [users.u1],
  );
  const request = async (user: string | null, kind: string, status: string, tier: string, cost: number, age: string) => {
    const { rows } = await db.query(
      "insert into ai_requests (user_id, kind, status, tier, cost_usd, created_at) values ($1, $2, $3, $4, $5, now() - $6::interval) returning id",
      [user ? users[user] : null, kind, status, tier, cost, age],
    );
    return rows[0].id as string;
  };
  const scan = async (requestId: string, user: string, age: string, correction?: { estimatedCalories: number; loggedCalories: number }) =>
    db.query(
      "insert into meal_scans (request_id, user_id, items, correction, created_at) values ($1, $2, '[]', $3, now() - $4::interval)",
      [requestId, users[user], correction ? JSON.stringify(correction) : null, age],
    );

  // Last 30 days.
  await scan(await request("u1", "meal_scan", "ok", "pro", 0.02, "1 day"), "u1", "1 day", { estimatedCalories: 600, loggedCalories: 450 });
  await request("u1", "meal_scan", "cached", "pro", 0, "1 day");
  await request("u1", "coach_summary", "ok", "pro", 0.01, "1 day");
  await request("u1", "meal_scan", "error", "pro", 0, "1 day");
  await scan(await request("u2", "meal_scan", "ok", "free", 0.03, "2 days"), "u2", "2 days", { estimatedCalories: 500, loggedCalories: 550 });
  await request("u2", "meal_scan", "no_food", "free", 0.01, "2 days");
  await request("u2", "meal_scan", "refused", "free", 0, "2 days");
  await scan(await request("u4", "meal_scan", "ok", "free", 0, "3 days"), "u4", "3 days");
  await request(null, "meal_scan", "ok", "free", 0.04, "4 days"); // a deleted account's cost row
  // Outside the 30-day window.
  await scan(await request("u3", "meal_scan", "ok", "free", 0.05, "45 days"), "u3", "45 days", { estimatedCalories: 100, loggedCalories: 900 });

  // Fixed dates for the monthly view, around a UTC month boundary.
  const fixed = (kind: string, status: string, tier: string, cost: number, at: string) =>
    db.query("insert into ai_requests (user_id, kind, status, tier, cost_usd, created_at) values (null, $1, $2, $3, $4, $5)", [kind, status, tier, cost, at]);
  await fixed("meal_scan", "ok", "pro", 0.1, "2026-01-15T12:00:00Z");
  await fixed("coach_summary", "ok", "pro", 0.05, "2026-01-31T23:30:00Z");
  await fixed("meal_scan", "ok", "pro", 0.2, "2026-02-01T00:30:00Z");
  await fixed("meal_scan", "cached", "free", 0, "2026-01-20T08:00:00Z");
  await fixed("meal_scan", "error", "free", 0, "2026-01-20T09:00:00Z");
});
after(async () => { await drop(); });

const num = (row: Record<string, unknown>) =>
  Object.fromEntries(Object.entries(row).map(([key, value]) => [key, value === null || value instanceof Date || typeof value === "number" ? value : isNaN(Number(value)) ? value : Number(value)]));

test("ai_cost_by_month groups by UTC month and tier, split by feature", async () => {
  // A non-UTC session must not move rows across the month boundary.
  const client = await db.connect();
  try {
    await client.query("set timezone = 'America/Los_Angeles'");
    const { rows } = await client.query(
      `select to_char(month, 'YYYY-MM-DD') as month_utc, tier, calls, meal_scans, coach_summaries, cache_hits, failures,
              cost_usd, meal_scan_cost_usd, coach_summary_cost_usd
       from ai_cost_by_month where month < '2026-03-01' order by 1, 2`,
    );
    assert.deepEqual(rows.map((r) => Object.values(num(r))), [
      ["2026-01-01", "free", 1, 0, 0, 1, 1, 0, 0, 0],
      ["2026-01-01", "pro", 2, 1, 1, 0, 0, 0.15, 0.1, 0.05],
      ["2026-02-01", "pro", 1, 1, 0, 0, 0, 0.2, 0.2, 0],
    ]);
  } finally {
    await client.query("reset timezone");
    client.release();
  }
});

test("ai_cost_per_active_user_30d divides 30-day spend by active users per tier", async () => {
  const { rows } = await db.query("select * from ai_cost_per_active_user_30d order by tier");
  assert.deepEqual(rows.map(num), [
    // spend: u1 0.03 (pro); u2 0.04 + u4 0 + deleted 0.04 (free). Active: u1, u2.
    { tier: "all", active_users: 2, ai_users: 3, cost_usd: 0.11, cost_per_active_user: 0.055, cost_per_ai_user: 0.036667 },
    { tier: "free", active_users: 1, ai_users: 2, cost_usd: 0.08, cost_per_active_user: 0.08, cost_per_ai_user: 0.04 },
    { tier: "pro", active_users: 1, ai_users: 1, cost_usd: 0.03, cost_per_active_user: 0.03, cost_per_ai_user: 0.03 },
  ]);
});

test("ai_top_users_30d ranks users by cost, user id only", async () => {
  const { rows } = await db.query("select * from ai_top_users_30d");
  assert.deepEqual(Object.keys(rows[0]).sort(), ["calls", "coach_summaries", "cost_usd", "meal_scans", "user_id"]);
  assert.deepEqual(rows.map(num), [
    { user_id: users.u2, calls: 3, meal_scans: 2, coach_summaries: 0, cost_usd: 0.04 },
    { user_id: users.u1, calls: 3, meal_scans: 1, coach_summaries: 1, cost_usd: 0.03 },
    { user_id: users.u4, calls: 1, meal_scans: 1, coach_summaries: 0, cost_usd: 0 },
  ]);
});

test("ai_scan_quality_30d reports failure, refusal, cache-hit and correction rates", async () => {
  const { rows } = await db.query("select * from ai_scan_quality_30d");
  assert.deepEqual(num(rows[0]), {
    attempts: 7, // 4 ok, 1 no_food, 1 refused, 1 error
    errors: 1,
    refusals: 1,
    cache_hits: 1,
    failure_rate: 0.1429,
    refusal_rate: 0.1429,
    cache_hit_rate: 0.1667, // 1 of 6 served scans
    scans: 3,
    corrected: 2,
    corrected_share: 0.6667,
    mean_abs_calorie_error: 100, // |450 - 600| and |550 - 500|
  });
});

test("ai_daily_cost counts only meal scans as scans", async () => {
  const { rows } = await db.query("select * from ai_daily_cost where day = date_trunc('day', timestamptz '2026-01-31T23:30:00Z')");
  assert.equal(rows.length, 1);
  assert.equal(Number(rows[0].scans), 0);
  assert.equal(Number(rows[0].cost_usd), 0.05);
});

test("cost views run with the caller's privileges (security_invoker) and ai_top_users_30d is marked pseudonymous", async () => {
  const { rows } = await db.query(
    `select c.relname, c.reloptions, obj_description(c.oid, 'pg_class') as comment
     from pg_class c where c.relkind = 'v' and c.relnamespace = current_schema()::regnamespace order by 1`,
  );
  assert.deepEqual(rows.map((r) => r.relname), ["ai_cost_by_month", "ai_cost_per_active_user_30d", "ai_daily_cost", "ai_scan_quality_30d", "ai_top_users_30d"]);
  for (const row of rows) assert.deepEqual(row.reloptions, ["security_invoker=true"], row.relname);
  assert.match(rows.find((r) => r.relname === "ai_top_users_30d").comment, /^Pseudonymous/);
});
