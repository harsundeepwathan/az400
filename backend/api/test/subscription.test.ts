import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { PRO_PRODUCT, startApp, storeKitChain, transactionPayload, type TestApp } from "./helpers.js";

const chain = storeKitChain();
const impostor = storeKitChain();
let app: TestApp;
before(async () => { app = await startApp({ appleRootCertificate: chain.root }); });
after(async () => { await app.close(); });

const post = (token: string, signed: string) =>
  app.request("POST", "/v1/subscription/transactions", { token, body: { signed_transaction: signed } });

test("a verified purchase unlocks Pro and the Pro scan allowance", async () => {
  const { access_token, user_id } = await app.signIn();
  const res = await post(access_token, await chain.sign(transactionPayload({ originalTransactionId: "t-pro", appAccountToken: user_id })));
  assert.equal(res.status, 200);
  assert.equal(res.json.tier, "pro");
  assert.equal(res.json.product_id, PRO_PRODUCT);
  const me = await app.request("GET", "/v1/me", { token: access_token });
  assert.equal(me.json.entitlement.tier, "pro");
  assert.equal(me.json.scans.limit, 30);
  assert.equal(me.json.scans.window, "day");
});

test("transactions not signed by the trusted root are rejected", async () => {
  const { access_token } = await app.signIn();
  const forged = await post(access_token, await impostor.sign(transactionPayload({ originalTransactionId: "t-forged" })));
  assert.equal(forged.status, 400);
  assert.equal(forged.json.reason, "untrusted_root");

  const valid = await chain.sign(transactionPayload({ originalTransactionId: "t-tamper" }));
  const [header, , signature] = valid.split(".");
  const tamperedPayload = Buffer.from(JSON.stringify(transactionPayload({ originalTransactionId: "t-tamper", expiresDate: Date.now() + 1e12 }))).toString("base64url");
  const tampered = await post(access_token, `${header}.${tamperedPayload}.${signature}`);
  assert.equal(tampered.status, 400);
  assert.equal(tampered.json.reason, "signature");
});

test("bundle, product and environment are checked", async () => {
  const { access_token } = await app.signIn();
  const cases: Array<[Record<string, unknown>, string]> = [
    [{ bundleId: "com.other.app" }, "bundle"],
    [{ productId: "app.vector.coins" }, "product"],
    [{ environment: "Sandbox" }, "environment"],
  ];
  for (const [override, reason] of cases) {
    const res = await post(access_token, await chain.sign(transactionPayload({ originalTransactionId: "t-" + reason, ...override })));
    assert.equal(res.status, 400);
    assert.equal(res.json.reason, reason);
  }
});

test("a purchase can't be moved to another account", async () => {
  const buyer = await app.signIn();
  const other = await app.signIn();
  const tx = await chain.sign(transactionPayload({ originalTransactionId: "t-owned" }));
  assert.equal((await post(buyer.access_token, tx)).status, 200);
  assert.equal((await post(other.access_token, tx)).status, 403, "replayed onto a second account");

  const bound = await chain.sign(transactionPayload({ originalTransactionId: "t-bound", appAccountToken: buyer.user_id }));
  assert.equal((await post(other.access_token, bound)).status, 403, "appAccountToken names another user");
});

test("expired or revoked subscriptions are free tier", async () => {
  const { access_token } = await app.signIn();
  const expired = await post(access_token, await chain.sign(transactionPayload({ originalTransactionId: "t-expired", expiresDate: Date.now() - 1000 })));
  assert.equal(expired.json.tier, "free");
  const revoked = await post(access_token, await chain.sign(transactionPayload({ originalTransactionId: "t-revoked", revocationDate: Date.now() - 1000 })));
  assert.equal(revoked.json.tier, "free");
});

test("without a configured root, verification is unavailable rather than skipped", async () => {
  const unconfigured = await startApp();
  try {
    const { access_token } = await unconfigured.signIn();
    const res = await unconfigured.request("POST", "/v1/subscription/transactions", {
      token: access_token,
      body: { signed_transaction: await chain.sign(transactionPayload()) },
    });
    assert.equal(res.status, 503);
  } finally {
    await unconfigured.close();
  }
});
