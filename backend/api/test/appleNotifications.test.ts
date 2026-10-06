import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { BUNDLE_ID, PRO_PRODUCT, startApp, storeKitChain, transactionPayload, type TestApp } from "./helpers.js";

const chain = storeKitChain();
const impostor = storeKitChain();
/** The test certificates are valid from their creation, so "earlier" signatures can't predate this. */
const chainBorn = Date.now();
let app: TestApp;
before(async () => { app = await startApp({ appleRootCertificate: chain.root }); });
after(async () => { await app.close(); });

const DAY = 86_400_000;

interface NotifyOptions {
  uuid?: string;
  subtype?: string;
  renewal?: Record<string, unknown>;
  bundleId?: string;
  environment?: string;
  signer?: ReturnType<typeof storeKitChain>;
  transactionSigner?: ReturnType<typeof storeKitChain>;
  signedDate?: number;
  data?: Record<string, unknown> | null;
  /** Extra top-level fields, e.g. `summary` or `externalPurchaseToken`. */
  extra?: Record<string, unknown>;
}

/** Builds an App Store Server Notification V2 exactly like Apple: a JWS whose data holds nested JWSs. */
async function notify(type: string, tx: Record<string, unknown> | null, options: NotifyOptions = {}) {
  const signedDate = options.signedDate ?? Date.now();
  let data: Record<string, unknown> | undefined;
  if (options.data !== null) {
    data = { appAppleId: 1234, bundleId: options.bundleId ?? BUNDLE_ID, bundleVersion: "1", environment: options.environment ?? "Production", status: 1, ...options.data };
    if (tx) {
      const payload = transactionPayload({ signedDate, ...tx });
      data.signedTransactionInfo = await (options.transactionSigner ?? chain).sign(payload);
      if (options.renewal) {
        data.signedRenewalInfo = await chain.sign({
          originalTransactionId: payload.originalTransactionId,
          autoRenewProductId: payload.productId,
          productId: payload.productId,
          autoRenewStatus: 1,
          environment: "Production",
          signedDate,
          ...options.renewal,
        });
      }
    }
  }
  const signedPayload = await (options.signer ?? chain).sign({
    notificationType: type,
    subtype: options.subtype,
    notificationUUID: options.uuid ?? randomUUID(),
    version: "2.0",
    signedDate,
    data,
    ...options.extra,
  });
  return app.request("POST", "/v1/apple/notifications", { body: { signedPayload } });
}

const purchase = async (token: string, tx: Record<string, unknown>) =>
  app.request("POST", "/v1/subscription/transactions", { token, body: { signed_transaction: await chain.sign(transactionPayload(tx)) } });
const me = async (token: string) => (await app.request("GET", "/v1/me", { token })).json.entitlement;
const subscription = async (id: string) => (await app.db.query("select * from subscriptions where original_transaction_id = $1", [id])).rows[0];

test("a renewal extends expiry without the app reopening", async () => {
  const { access_token } = await app.signIn();
  const id = "n-renew";
  const soon = Date.now() + DAY;
  assert.equal((await purchase(access_token, { originalTransactionId: id, expiresDate: soon, signedDate: chainBorn })).status, 200);
  assert.equal(Date.parse((await me(access_token)).expires_at), soon);

  const renewed = Date.now() + 31 * DAY;
  const res = await notify("DID_RENEW", { originalTransactionId: id, transactionId: "n-renew-2", expiresDate: renewed }, { renewal: {} });
  assert.equal(res.status, 200);
  assert.equal(res.json.status, "applied");
  const entitlement = await me(access_token);
  assert.equal(entitlement.tier, "pro");
  assert.equal(Date.parse(entitlement.expires_at), renewed);
  assert.equal((await subscription(id)).auto_renew, true);
});

test("a refund or revocation ends Pro", async () => {
  for (const type of ["REFUND", "REVOKE"]) {
    const { access_token } = await app.signIn();
    const id = "n-" + type.toLowerCase();
    await purchase(access_token, { originalTransactionId: id, signedDate: chainBorn });
    assert.equal((await me(access_token)).tier, "pro");
    const res = await notify(type, { originalTransactionId: id, revocationDate: Date.now() - 1000 });
    assert.equal(res.status, 200);
    assert.equal(res.json.status, "applied");
    assert.equal((await me(access_token)).tier, "free", type);
    assert.ok((await subscription(id)).revoked_at);
  }
});

test("a stale transaction posted after a refund doesn't restore Pro", async () => {
  const { access_token } = await app.signIn();
  const id = "n-stale";
  const purchasedSigned = chainBorn;
  const stale = await chain.sign(transactionPayload({ originalTransactionId: id, signedDate: purchasedSigned }));
  await app.request("POST", "/v1/subscription/transactions", { token: access_token, body: { signed_transaction: stale } });
  await notify("REFUND", { originalTransactionId: id, revocationDate: Date.now() - 1000 });
  const replay = await app.request("POST", "/v1/subscription/transactions", { token: access_token, body: { signed_transaction: stale } });
  assert.equal(replay.status, 200);
  assert.equal(replay.json.tier, "free");
});

test("a duplicate notification is ignored", async () => {
  const { access_token } = await app.signIn();
  const id = "n-dup";
  await purchase(access_token, { originalTransactionId: id, signedDate: chainBorn });
  const uuid = randomUUID();
  const first = await notify("DID_RENEW", { originalTransactionId: id, expiresDate: Date.now() + 40 * DAY }, { uuid });
  assert.equal(first.json.status, "applied");
  // Same notificationUUID again (Apple retried), even with different contents: nothing changes.
  const again = await notify("REFUND", { originalTransactionId: id, revocationDate: Date.now() }, { uuid });
  assert.equal(again.status, 200);
  assert.equal(again.json.status, "duplicate");
  assert.equal((await me(access_token)).tier, "pro");
  const { rows } = await app.db.query("select count(*)::int as n from apple_notifications where notification_uuid = $1", [uuid]);
  assert.equal(rows[0].n, 1);
});

test("forged chains are rejected, outer or nested", async () => {
  const outer = await notify("DID_RENEW", { originalTransactionId: "n-forged" }, { signer: impostor });
  assert.equal(outer.status, 400);
  assert.equal(outer.json.error, "invalid_notification");
  assert.equal(outer.json.reason, "untrusted_root");

  const nested = await notify("DID_RENEW", { originalTransactionId: "n-forged" }, { transactionSigner: impostor });
  assert.equal(nested.status, 400);
  assert.equal(nested.json.reason, "untrusted_root");
  assert.equal(await subscription("n-forged"), undefined);

  const garbage = await app.request("POST", "/v1/apple/notifications", { body: { signedPayload: "not.a.jws" } });
  assert.equal(garbage.status, 400);
  assert.equal((await app.request("POST", "/v1/apple/notifications", { body: {} })).status, 400);
});

test("wrong bundle or environment is rejected", async () => {
  const outer = await notify("SUBSCRIBED", { originalTransactionId: "n-bundle" }, { bundleId: "com.other.app" });
  assert.equal(outer.status, 400);
  assert.equal(outer.json.reason, "bundle");
  const nested = await notify("SUBSCRIBED", { originalTransactionId: "n-bundle", bundleId: "com.other.app" });
  assert.equal(nested.status, 400);
  assert.equal(nested.json.reason, "bundle");
  const sandbox = await notify("SUBSCRIBED", { originalTransactionId: "n-bundle", environment: "Sandbox" }, { environment: "Sandbox" });
  assert.equal(sandbox.status, 400);
  assert.equal(sandbox.json.reason, "environment");
  assert.equal(await subscription("n-bundle"), undefined);
});

test("an unknown transaction is stored unlinked and claimed when the app posts it", async () => {
  const id = "n-unlinked";
  const res = await notify("SUBSCRIBED", { originalTransactionId: id }, { subtype: "INITIAL_BUY" });
  assert.equal(res.status, 200);
  assert.equal(res.json.status, "unlinked");
  assert.equal((await subscription(id)).user_id, null);

  const { access_token, user_id } = await app.signIn();
  const claimed = await purchase(access_token, { originalTransactionId: id });
  assert.equal(claimed.status, 200);
  assert.equal(claimed.json.tier, "pro");
  assert.equal((await subscription(id)).user_id, user_id);
  // Once claimed, it can't be moved to someone else.
  const other = await app.signIn();
  assert.equal((await purchase(other.access_token, { originalTransactionId: id })).status, 403);
});

test("appAccountToken links a transaction the app never posted", async () => {
  const { access_token, user_id } = await app.signIn();
  const res = await notify("SUBSCRIBED", { originalTransactionId: "n-token", appAccountToken: user_id });
  assert.equal(res.json.status, "applied");
  assert.equal((await me(access_token)).tier, "pro");
});

test("billing grace period keeps Pro until it expires; renewal status is recorded", async () => {
  const { access_token, user_id } = await app.signIn();
  const id = "n-grace";
  const lapsed = Date.now() - 1000;
  const t0 = Date.now();
  const failed = await notify("DID_FAIL_TO_RENEW", { originalTransactionId: id, appAccountToken: user_id, expiresDate: lapsed }, {
    subtype: "GRACE_PERIOD", signedDate: t0, renewal: { gracePeriodExpiresDate: Date.now() + 6 * DAY, isInBillingRetryPeriod: true },
  });
  assert.equal(failed.json.status, "applied");
  assert.equal((await me(access_token)).tier, "pro", "in grace period");

  const off = await notify("DID_CHANGE_RENEWAL_STATUS", { originalTransactionId: id, expiresDate: lapsed }, {
    subtype: "AUTO_RENEW_DISABLED", signedDate: t0 + 1000, renewal: { autoRenewStatus: 0, gracePeriodExpiresDate: Date.now() + 6 * DAY },
  });
  assert.equal(off.status, 200);
  assert.equal((await subscription(id)).auto_renew, false);

  await notify("GRACE_PERIOD_EXPIRED", { originalTransactionId: id, expiresDate: lapsed }, {
    signedDate: t0 + 2000, renewal: { autoRenewStatus: 0, gracePeriodExpiresDate: Date.now() - 500 },
  });
  assert.equal((await me(access_token)).tier, "free");

  await notify("EXPIRED", { originalTransactionId: id, expiresDate: lapsed }, { subtype: "VOLUNTARY", signedDate: t0 + 3000 });
  assert.equal((await me(access_token)).tier, "free");
});

test("notifications without a Pro transaction are acknowledged and not applied", async () => {
  const testPing = await notify("TEST", null);
  assert.equal(testPing.status, 200);
  assert.equal(testPing.json.status, "ignored");
  const summary = await notify("RENEWAL_EXTENSION", null, {
    data: null, subtype: "SUMMARY", extra: { summary: { bundleId: BUNDLE_ID, environment: "Production", succeededCount: 3, failedCount: 0 } },
  });
  assert.equal(summary.status, 200);
  assert.equal(summary.json.status, "ignored");
  const otherProduct = await notify("SUBSCRIBED", { originalTransactionId: "n-coins", productId: "app.vector.coins" });
  assert.equal(otherProduct.json.status, "ignored");
  assert.equal(await subscription("n-coins"), undefined);
});

test("without a configured root, notifications are not accepted unverified", async () => {
  const unconfigured = await startApp();
  try {
    const signedPayload = await chain.sign({ notificationType: "TEST", notificationUUID: randomUUID(), signedDate: Date.now() });
    const res = await unconfigured.request("POST", "/v1/apple/notifications", { body: { signedPayload } });
    assert.equal(res.status, 503);
  } finally {
    await unconfigured.close();
  }
});

test("a notification without data must name this app in summary or externalPurchaseToken", async () => {
  const none = await notify("TEST", null, { data: null });
  assert.equal(none.status, 400);
  assert.equal(none.json.reason, "bundle");

  const otherApp = await notify("RENEWAL_EXTENSION", null, { data: null, extra: { summary: { bundleId: "com.other.app", environment: "Production" } } });
  assert.equal(otherApp.status, 400);
  assert.equal(otherApp.json.reason, "bundle");

  const sandboxSummary = await notify("RENEWAL_EXTENSION", null, { data: null, extra: { summary: { bundleId: BUNDLE_ID, environment: "Sandbox" } } });
  assert.equal(sandboxSummary.status, 400);
  assert.equal(sandboxSummary.json.reason, "environment");

  const noEnvironment = await notify("RENEWAL_EXTENSION", null, { data: null, extra: { summary: { bundleId: BUNDLE_ID } } });
  assert.equal(noEnvironment.status, 400);
  assert.equal(noEnvironment.json.reason, "environment");

  const token = (externalPurchaseId: string, bundleId = BUNDLE_ID) =>
    ({ data: null, extra: { externalPurchaseToken: { externalPurchaseId, tokenCreationDate: Date.now(), appAppleId: 1234, bundleId } } });
  const external = await notify("EXTERNAL_PURCHASE_TOKEN", null, { subtype: "UNREPORTED", ...token("ext-1") });
  assert.equal(external.status, 200);
  assert.equal(external.json.status, "ignored");
  assert.equal((await notify("EXTERNAL_PURCHASE_TOKEN", null, token("SANDBOX_ext-2"))).json.reason, "environment");
  assert.equal((await notify("EXTERNAL_PURCHASE_TOKEN", null, token("ext-3", "com.other.app"))).json.reason, "bundle");

  const { rows } = await app.db.query("select environment from apple_notifications where notification_type = 'EXTERNAL_PURCHASE_TOKEN'");
  assert.deepEqual(rows.map((r) => r.environment), ["Production"]);
});

test("a refund of an earlier period keeps the current paid period; a refund of the current one ends Pro", async () => {
  const { access_token, user_id } = await app.signIn();
  const id = "n-old-refund";
  const firstExpiry = Date.now() + 2 * DAY;
  await purchase(access_token, { originalTransactionId: id, transactionId: "old-1", expiresDate: firstExpiry, signedDate: chainBorn });
  const t0 = Date.now();
  const currentExpiry = Date.now() + 32 * DAY;
  const renewed = await notify("DID_RENEW", { originalTransactionId: id, transactionId: "old-2", expiresDate: currentExpiry, appAccountToken: user_id }, { signedDate: t0 });
  assert.equal(renewed.json.status, "applied");

  // Apple refunds the first period's transaction later: it is the newest-signed JWS but for an older period.
  const oldRefund = await notify("REFUND", { originalTransactionId: id, transactionId: "old-1", expiresDate: firstExpiry, revocationDate: t0 + 500 }, { signedDate: t0 + 1000 });
  assert.equal(oldRefund.status, 200);
  assert.equal(oldRefund.json.status, "applied");
  const kept = await me(access_token);
  assert.equal(kept.tier, "pro");
  assert.equal(kept.product_id, PRO_PRODUCT);
  assert.equal(Date.parse(kept.expires_at), currentExpiry);
  assert.equal((await subscription(id)).revoked_at, null);

  const currentRefund = await notify("REFUND", { originalTransactionId: id, transactionId: "old-2", expiresDate: currentExpiry, revocationDate: t0 + 1500 }, { signedDate: t0 + 2000 });
  assert.equal(currentRefund.json.status, "applied");
  assert.equal((await me(access_token)).tier, "free");
  assert.ok((await subscription(id)).revoked_at);
});

test("a deleted account's renewed subscription can be claimed by the next account that posts it", async () => {
  const buyerA = await app.signIn("apple-person-relink");
  const id = "n-relink";
  const bought = await purchase(buyerA.access_token, { originalTransactionId: id, appAccountToken: buyerA.user_id, signedDate: chainBorn });
  assert.equal(bought.json.tier, "pro");
  assert.equal((await app.request("DELETE", "/v1/me", { token: buyerA.access_token })).status, 204);
  assert.equal(await subscription(id), undefined, "the subscription row goes with the account");

  // The renewal still carries A's id as appAccountToken; A no longer exists, so the row is recreated unlinked.
  const renewal = await notify("DID_RENEW", { originalTransactionId: id, transactionId: "n-relink-2", appAccountToken: buyerA.user_id, expiresDate: Date.now() + 40 * DAY });
  assert.equal(renewal.json.status, "unlinked");
  assert.equal((await subscription(id)).user_id, null);

  // The same person signs in again (a new account B) and the app posts the transaction.
  const userB = await app.signIn("apple-person-relink");
  assert.notEqual(userB.user_id, buyerA.user_id);
  const claimed = await purchase(userB.access_token, { originalTransactionId: id, transactionId: "n-relink-2", appAccountToken: buyerA.user_id, expiresDate: Date.now() + 40 * DAY });
  assert.equal(claimed.status, 200);
  assert.equal(claimed.json.tier, "pro");
  assert.equal((await subscription(id)).user_id, userB.user_id);

  // Once B holds it, a third account can't take it, token or not.
  const userC = await app.signIn();
  assert.equal((await purchase(userC.access_token, { originalTransactionId: id, appAccountToken: buyerA.user_id })).status, 403);
});

test("apple_notifications rows older than 90 days are pruned, at most once an hour", async () => {
  const fresh = await startApp({ appleRootCertificate: chain.root });
  try {
    const old = async (uuid: string, age: string) =>
      fresh.db.query(
        `insert into apple_notifications (notification_uuid, notification_type, outcome, signed_at, received_at)
         values ($1, 'TEST', 'ignored', now() - $2::interval, now() - $2::interval)`,
        [uuid, age],
      );
    const expired = randomUUID();
    const recent = randomUUID();
    await old(expired, "91 days");
    await old(recent, "89 days");
    const ping = async () => {
      const signedPayload = await chain.sign({ notificationType: "TEST", notificationUUID: randomUUID(), signedDate: Date.now(), data: { bundleId: BUNDLE_ID, environment: "Production" } });
      return fresh.request("POST", "/v1/apple/notifications", { body: { signedPayload } });
    };
    assert.equal((await ping()).json.status, "ignored");
    const left = async () => (await fresh.db.query("select notification_uuid from apple_notifications where received_at < now() - interval '1 day' order by received_at")).rows.map((r) => r.notification_uuid);
    assert.deepEqual(await left(), [recent]);

    // Within the hour, the next notification doesn't run the delete again.
    const later = randomUUID();
    await old(later, "100 days");
    assert.equal((await ping()).json.status, "ignored");
    assert.deepEqual(await left(), [later, recent]);
  } finally {
    await fresh.close();
  }
});
