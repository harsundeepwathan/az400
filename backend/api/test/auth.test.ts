import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { startApp, type TestApp } from "./helpers.js";

let app: TestApp;
before(async () => { app = await startApp(); });
after(async () => { await app.close(); });

test("Sign in with Apple creates one user per Apple id", async () => {
  const first = await app.signIn("apple-1");
  const second = await app.signIn("apple-1");
  assert.equal(first.user_id, second.user_id);
  assert.notEqual(first.refresh_token, second.refresh_token);
  const { rows } = await app.db.query("select count(*)::int as n from users where apple_sub = 'apple-1'");
  assert.equal(rows[0].n, 1);
});

test("identity tokens for another app or with the wrong nonce are rejected", async () => {
  const wrongAudience = await app.apple.token("apple-2", { audience: "com.someone.else" });
  assert.equal((await app.request("POST", "/v1/auth/apple", { body: { identity_token: wrongAudience } })).status, 401);

  const hashed = createHash("sha256").update("raw-nonce").digest("hex");
  const token = await app.apple.token("apple-2", { nonce: hashed });
  assert.equal((await app.request("POST", "/v1/auth/apple", { body: { identity_token: token, nonce: "other" } })).status, 401);
  assert.equal((await app.request("POST", "/v1/auth/apple", { body: { identity_token: token, nonce: "raw-nonce" } })).status, 200);

  assert.equal((await app.request("POST", "/v1/auth/apple", { body: { identity_token: "not-a-jwt" } })).status, 401);
});

test("refresh rotates tokens and detects reuse", async () => {
  const session = await app.signIn();
  const rotated = await app.request("POST", "/v1/auth/refresh", { body: { refresh_token: session.refresh_token } });
  assert.equal(rotated.status, 200);
  assert.equal(rotated.json.user_id, session.user_id);

  // Replaying the old token (e.g. it was stolen) revokes the whole family.
  const replay = await app.request("POST", "/v1/auth/refresh", { body: { refresh_token: session.refresh_token } });
  assert.equal(replay.status, 401);
  assert.equal(replay.json.error, "refresh_token_reused");
  const newer = await app.request("POST", "/v1/auth/refresh", { body: { refresh_token: rotated.json.refresh_token } });
  assert.equal(newer.status, 401, "the attacker's and the victim's tokens both stop working");

  const { rows } = await app.db.query("select token_hash from refresh_tokens limit 1");
  assert.equal(rows[0].token_hash.length, 32, "only hashes are stored");
});

test("protected routes need a valid access token", async () => {
  assert.equal((await app.request("GET", "/v1/me")).status, 401);
  assert.equal((await app.request("GET", "/v1/me", { token: "garbage" })).status, 401);
  const session = await app.signIn();
  const me = await app.request("GET", "/v1/me", { token: session.access_token });
  assert.equal(me.status, 200);
  assert.equal(me.json.entitlement.tier, "free");
  assert.deepEqual(
    { used: me.json.scans.used, limit: me.json.scans.limit, remaining: me.json.scans.remaining },
    { used: 0, limit: 3, remaining: 3 },
  );
});

test("sign out revokes refresh tokens", async () => {
  const session = await app.signIn();
  assert.equal((await app.request("POST", "/v1/auth/sign-out", { token: session.access_token })).status, 204);
  assert.equal((await app.request("POST", "/v1/auth/refresh", { body: { refresh_token: session.refresh_token } })).status, 401);
});

test("unknown routes and methods", async () => {
  assert.equal((await app.request("GET", "/nope")).status, 404);
  assert.equal((await app.request("GET", "/v1/auth/apple")).status, 405);
  assert.equal((await app.request("GET", "/health")).status, 200);
});
