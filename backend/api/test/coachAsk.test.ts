import { after, before, beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { MAX_ASKS_PER_DAY, rejectAnswer } from "../src/coachAsk.js";
import { CoachDigest } from "../src/coach.js";
import { PRO_PRODUCT, startApp, type TestApp } from "./helpers.js";

let app: TestApp;
before(async () => { app = await startApp(); });
after(async () => { await app.close(); });
beforeEach(() => { app.claude.reply = answerReply(GOOD); app.claude.calls.length = 0; app.claude.options.length = 0; });

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

const QUESTION = "Why is my weight not going up?";
const GOOD = "Your trend weight is 77.4 kg, slightly below 77.9 kg 14 days ago, while calories averaged 2,240 against a 2300 target. " +
  "Protein hit target on only 2 of 6 logged days, so eating closer to your targets is the likeliest fix.";
const INVENTED = "You are about 60 kcal short each day, which over 14 days adds up to 840 kcal.";

function answerReply(answer: string, stop_reason = "end_turn") {
  return {
    model: "claude-opus-5-5",
    stop_reason,
    content: stop_reason === "refusal" ? [] : [{ type: "text", text: JSON.stringify({ answer }) }],
    usage: { input_tokens: 900, output_tokens: 120, cache_read_input_tokens: 700, cache_creation_input_tokens: 0 },
  };
}

async function proUser() {
  const session = await app.signIn();
  await app.db.query(
    `insert into subscriptions (original_transaction_id, user_id, product_id, environment, purchased_at, expires_at)
     values ($1, $2, $3, 'Production', now() - interval '1 day', now() + interval '30 days')`,
    ["ask-" + session.user_id, session.user_id, PRO_PRODUCT],
  );
  return session;
}

const ask = (token: string, body: unknown = { digest: digest(), question: QUESTION }) =>
  app.request("POST", "/v1/coach/ask", { token, body });
const requests = async (userId: string) =>
  (await app.db.query("select * from ai_requests where user_id = $1 and kind = 'coach_ask' order by created_at", [userId])).rows;

test("free users get 402 and no model call; signed-out users get 401", async () => {
  const { access_token } = await app.signIn();
  const res = await ask(access_token);
  assert.equal(res.status, 402);
  assert.deepEqual(res.json, { error: "pro_required" });
  assert.equal(app.claude.calls.length, 0);
  assert.equal((await app.request("POST", "/v1/coach/ask", { body: { digest: digest(), question: QUESTION } })).status, 401);
});

test("bad questions and digests are rejected with 400 before any model call", async () => {
  const { access_token } = await proUser();
  for (const body of [{ digest: digest(), question: "" }, { digest: digest(), question: "x".repeat(201) },
                      { digest: digest() }, { question: QUESTION }, { digest: { ...digest(), unit: "stone" }, question: QUESTION }]) {
    assert.equal((await ask(access_token, body)).status, 400, JSON.stringify(body).slice(0, 80));
  }
  assert.equal(app.claude.calls.length, 0);
});

test("a good answer is returned with the questions left today, and the call is recorded with its cost", async () => {
  const { access_token, user_id } = await proUser();
  const res = await ask(access_token);
  assert.equal(res.status, 200);
  assert.equal(res.json.answer, GOOD);
  assert.equal(res.json.asks_left_today, MAX_ASKS_PER_DAY - 1);
  const call = app.claude.calls[0];
  assert.match(call.messages[0].content[0].text, /Why is my weight not going up\?/);
  assert.equal(app.claude.options[0].maxRetries, 0);
  const rows = await requests(user_id);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].status, "ok");
  assert.ok(Number(rows[0].cost_usd) > 0);
});

test("an answer with invented numbers is retried once, then fails with 503", async () => {
  const { access_token, user_id } = await proUser();
  app.claude.reply = [answerReply(INVENTED), answerReply(GOOD)];
  const fixed = await ask(access_token);
  assert.equal(fixed.status, 200);
  assert.equal(app.claude.calls.length, 2);
  assert.match(app.claude.calls[1].messages[0].content[0].text, /not in the digest or the question \(60, 840\)/);

  app.claude.reply = answerReply(INVENTED);
  assert.equal((await ask(access_token)).status, 503);
  // Rows in one request share a timestamp, so compare counts rather than order.
  const statuses = (await requests(user_id)).map((r) => r.status).sort();
  assert.deepEqual(statuses, ["error", "error", "error", "ok"]);
});

test("numbers from the question may be used in the answer", () => {
  const d = CoachDigest.parse(digest());
  assert.equal(rejectAnswer("Your Back Squat estimated max is 101.3 kg, so 110 kg is not in reach yet.", d, "Can I squat 110 kg?"), null);
  assert.deepEqual(rejectAnswer("Try 105 kg.", d, "Can I squat 110 kg?"), { code: "invented_number", invented: [105] });
  assert.deepEqual(rejectAnswer("x".repeat(501), d, QUESTION), { code: "answer_length" });
});

test("refusals and API errors return 503 busy", async () => {
  const { access_token } = await proUser();
  app.claude.reply = answerReply("", "refusal");
  assert.equal((await ask(access_token)).status, 503);
  app.claude.reply = new Error("boom");
  assert.equal((await ask(access_token)).status, 503);
});

test("the daily cap applies to model calls", async () => {
  const { access_token, user_id } = await proUser();
  for (let i = 0; i < MAX_ASKS_PER_DAY; i++) {
    await app.db.query("insert into ai_requests (user_id, kind, status, tier, created_at) values ($1, 'coach_ask', 'ok', 'pro', now())", [user_id]);
  }
  const res = await ask(access_token);
  assert.equal(res.status, 429);
  assert.ok(res.json.retry_after_seconds > 60);
  assert.equal(app.claude.calls.length, 0);
});

test("one question at a time: a pending call blocks a parallel one", async () => {
  const { access_token, user_id } = await proUser();
  await app.db.query("insert into ai_requests (user_id, kind, status, tier, created_at) values ($1, 'coach_ask', 'pending', 'pro', now())", [user_id]);
  const res = await ask(access_token);
  assert.equal(res.status, 429);
  assert.equal(res.json.retry_after_seconds, 15);
});
