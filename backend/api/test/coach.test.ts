import { after, before, beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { CoachDigest, numbersIn, rejectSummary } from "../src/coach.js";
import { PRO_PRODUCT, startApp, type TestApp } from "./helpers.js";

let app: TestApp;
before(async () => { app = await startApp(); });
after(async () => { await app.close(); });
beforeEach(() => { app.claude.reply = summaryReply(GOOD); app.claude.calls.length = 0; });

/** The example digest from the shared contract in docs/tasks/p1-tasklist.md. */
const digest = () => ({
  date: "2026-10-06", goal: "build_muscle", unit: "kg",
  training: { workouts_last_7d: 4, workouts_prev_7d: 3, planned_per_week: 4,
              volume_change_pct: 6.5,
              prs_last_14d: [{ exercise: "Back Squat", weight: 82.5, reps: 8 }],
              main_lift: { exercise: "Back Squat", e1rm_now: 101.3, e1rm_30d_ago: 96.3 } },
  nutrition: { days_logged_last_7d: 6, avg_calories: 2240, target_calories: 2300,
               avg_protein: 128, target_protein: 150, protein_days_hit: 2 },
  body: { trend_weight_now: 77.4, trend_weight_14d_ago: 77.9, weigh_ins_last_14d: 11 },
  recommendations: ["Increase Back Squat to 85 kg × 8"],
});

const GOOD =
  "You trained 4 times in the last 7 days against a plan of 4, and your Back Squat estimated 1RM rose to 101.3 kg from 96.3 kg 30 days ago. " +
  "Calories averaged 2,240 against a 2300 target, but protein averaged 128 g against 150 g and hit target on only 2 days, which can slow muscle gain. " +
  "Your trend weight is 77.4 kg, slightly below 77.9 kg, so try Back Squat at 85 kg × 8 and add protein at each meal.";
const INVENTED = "You trained 4 times and your trend weight is down 0.5 kg in 14 days. Protein was 22 g short of your target on average.";

function summaryReply(summary: string, stop_reason = "end_turn") {
  return {
    model: "claude-opus-5-5",
    stop_reason,
    content: stop_reason === "refusal" ? [] : [{ type: "text", text: JSON.stringify({ summary }) }],
    usage: { input_tokens: 900, output_tokens: 150, cache_read_input_tokens: 0, cache_creation_input_tokens: 700 },
  };
}

async function proUser() {
  const session = await app.signIn();
  await app.db.query(
    `insert into subscriptions (original_transaction_id, user_id, product_id, environment, purchased_at, expires_at)
     values ($1, $2, $3, 'Production', now() - interval '1 day', now() + interval '30 days')`,
    ["coach-" + session.user_id, session.user_id, PRO_PRODUCT],
  );
  return session;
}

const summarize = (token: string, body: unknown = { digest: digest() }) => app.request("POST", "/v1/coach/summary", { token, body });
const requests = async (userId: string) =>
  (await app.db.query("select * from ai_requests where user_id = $1 and kind = 'coach_summary' order by created_at, status desc", [userId])).rows;

test("free users get 402 and no model call", async () => {
  const { access_token } = await app.signIn();
  const res = await summarize(access_token);
  assert.equal(res.status, 402);
  assert.deepEqual(res.json, { error: "pro_required" });
  assert.equal(app.claude.calls.length, 0);
  assert.equal((await app.request("POST", "/v1/coach/summary", { body: { digest: digest() } })).status, 401);
});

test("an expired or revoked subscription is not Pro", async () => {
  const { access_token, user_id } = await app.signIn();
  await app.db.query(
    `insert into subscriptions (original_transaction_id, user_id, product_id, environment, purchased_at, expires_at, revoked_at)
     values ($1, $2, $3, 'Production', now() - interval '40 days', now() + interval '1 day', now())`,
    ["coach-revoked-" + user_id, user_id, PRO_PRODUCT],
  );
  assert.equal((await summarize(access_token)).status, 402);
});

test("invalid digests are rejected with 400 before any model call", async () => {
  const { access_token } = await proUser();
  const invalid: Array<(d: any) => void> = [
    (d) => { d.goal = "get_huge"; },
    (d) => { d.unit = "stone"; },
    (d) => { d.date = "06/10/2026"; },
    (d) => { delete d.training.workouts_last_7d; },
    (d) => { d.nutrition.avg_calories = -1; },
    (d) => { d.training.prs_last_14d = Array(6).fill({ exercise: "Bench", weight: 60, reps: 5 }); },
    (d) => { d.recommendations = Array(6).fill("Rest"); },
    (d) => { d.recommendations = ["x".repeat(121)]; },
    (d) => { d.training.main_lift.exercise = ""; },
    (d) => { d.body.weigh_ins_last_14d = "11"; },
  ];
  for (const mutate of invalid) {
    const d = digest();
    mutate(d);
    const res = await summarize(access_token, { digest: d });
    assert.equal(res.status, 400, JSON.stringify(d));
    assert.equal(res.json.error, "invalid_request");
  }
  assert.equal((await summarize(access_token, { summary: "hi" })).status, 400);
  assert.equal(app.claude.calls.length, 0);
});

test("a summary is generated once, with usage and cost recorded, then served from cache the same day", async () => {
  const { access_token, user_id } = await proUser();
  const first = await summarize(access_token);
  assert.equal(first.status, 200);
  assert.equal(first.json.summary, GOOD);
  assert.equal(first.json.cached, false);
  assert.ok(!Number.isNaN(Date.parse(first.json.generated_at)));

  const call = app.claude.calls[0];
  assert.equal(call.model, "claude-opus-5-5");
  assert.deepEqual(call.betas, ["server-side-fallback-2026-07-01"]);
  assert.equal(call.fallbacks, "default");
  assert.equal(call.output_config.format.type, "json_schema");
  assert.deepEqual(call.output_config.format.schema.required, ["summary"]);
  assert.deepEqual(call.system[0].cache_control, { type: "ephemeral" });
  assert.match(call.messages[0].content[0].text, /"protein_days_hit":2/);

  const [row] = await requests(user_id);
  assert.equal(row.status, "ok");
  assert.equal(row.tier, "pro");
  assert.equal(row.input_tokens, 900);
  assert.equal(row.output_tokens, 150);
  assert.equal(row.cache_write_tokens, 700);
  // 900 × $5 + 150 × $25 + 700 × $6.25 per million tokens
  assert.equal(Number(row.cost_usd), 0.012625);

  const second = await summarize(access_token);
  assert.equal(second.status, 200);
  assert.equal(second.json.cached, true);
  assert.equal(second.json.summary, GOOD);
  assert.equal(second.json.generated_at, first.json.generated_at);
  assert.equal(app.claude.calls.length, 1, "no second model call the same day");
  assert.deepEqual((await requests(user_id)).map((r) => r.status).sort(), ["cached", "ok"]);
  const { rows } = await app.db.query("select count(*)::int as n from coach_summaries where user_id = $1", [user_id]);
  assert.equal(rows[0].n, 1);
});

test("output with an invented number is rejected and retried once", async () => {
  const { access_token, user_id } = await proUser();
  app.claude.reply = [summaryReply(INVENTED), summaryReply(GOOD)];
  const res = await summarize(access_token);
  assert.equal(res.status, 200);
  assert.equal(res.json.summary, GOOD);
  assert.equal(app.claude.calls.length, 2);
  assert.match(app.claude.calls[1].messages[0].content[0].text, /not in the digest \(0\.5, 22\)/);
  const rows = await requests(user_id);
  assert.deepEqual(rows.map((r) => [r.status, r.error_code]).sort(), [["error", "invented_number"], ["ok", null]]);
  assert.ok(rows.every((r) => Number(r.cost_usd) > 0), "both calls are paid for and recorded");
});

test("two rejected drafts fail with 503 and store nothing; the daily call cap then applies", async () => {
  const { access_token, user_id } = await proUser();
  app.claude.reply = summaryReply(INVENTED);
  const res = await summarize(access_token);
  assert.equal(res.status, 503);
  assert.equal(res.json.error, "busy");
  assert.equal(app.claude.calls.length, 2);
  const { rows } = await app.db.query("select count(*)::int as n from coach_summaries where user_id = $1", [user_id]);
  assert.equal(rows[0].n, 0);

  app.claude.reply = summaryReply("x".repeat(601));
  assert.equal((await summarize(access_token)).status, 503, "too long is rejected too");
  assert.equal(app.claude.calls.length, 4);
  const capped = await summarize(access_token);
  assert.equal(capped.status, 429);
  assert.equal(capped.json.error, "rate_limited");
  assert.equal(app.claude.calls.length, 4);
});

test("refusals and API errors return 503 busy", async () => {
  const { access_token, user_id } = await proUser();
  app.claude.reply = summaryReply("", "refusal");
  assert.equal((await summarize(access_token)).status, 503);
  app.claude.reply = new Error("boom");
  assert.equal((await summarize(access_token)).status, 503);
  assert.deepEqual((await requests(user_id)).map((r) => r.status).sort(), ["error", "refused"]);
});

test("nullable fields accept null or a missing key", async () => {
  const { access_token } = await proUser();
  const d: any = digest();
  d.training.volume_change_pct = null;
  d.training.main_lift = null;
  d.nutrition.avg_calories = null;
  delete d.nutrition.avg_protein;
  delete d.body.trend_weight_now;
  d.body.trend_weight_14d_ago = null;
  app.claude.reply = summaryReply("You trained 4 times in the last 7 days, matching your plan of 4. Logging a few more weigh-ins will make your trend clearer.");
  const res = await summarize(access_token, { digest: d });
  assert.equal(res.status, 200);
  assert.match(app.claude.calls[0].messages[0].content[0].text, /"main_lift":null/);
});

test("the numeric check accepts digest numbers and roundings only", () => {
  const d = CoachDigest.parse(digest());
  assert.equal(rejectSummary(GOOD, d), null);
  assert.equal(rejectSummary("Your estimated 1RM is about 101 kg, up 6.5% in volume.", d), null);
  assert.deepEqual(rejectSummary("You lost 0.5 kg.", d), { code: "invented_number", invented: [0.5] });
  assert.deepEqual(rejectSummary("Squat 102 kg next.", d), { code: "invented_number", invented: [102] });
  assert.deepEqual(numbersIn("2,240 kcal, e1RM 101.3, 85 kg × 8."), [2240, 101.3, 85, 8]);
});

test("parallel first requests make one model call", async () => {
  const { access_token, user_id } = await proUser();
  const results = await Promise.all(Array.from({ length: 4 }, () => summarize(access_token)));
  assert.equal(app.claude.calls.length, 1);
  assert.ok(results.every((r) => r.status === 200 || (r.status === 429 && r.json.error === "rate_limited")), JSON.stringify(results));
  assert.equal(results.filter((r) => r.status === 200 && r.json.cached === false).length, 1);
  const { rows } = await app.db.query("select count(*)::int as n from coach_summaries where user_id = $1", [user_id]);
  assert.equal(rows[0].n, 1);
});
