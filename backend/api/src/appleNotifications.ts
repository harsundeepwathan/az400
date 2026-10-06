import { z } from "zod";
import { upsertSubscription, verifyAppleJws, type RenewalState, type TransactionPayload } from "./appStore.js";
import { transaction, type Db } from "./db.js";
import { HttpError, type Logger } from "./http.js";

/**
 * App Store Server Notifications V2. Apple POSTs `{signedPayload}` (a JWS
 * signed with the same x5c chain format as StoreKit transactions); its
 * `data.signedTransactionInfo` and `data.signedRenewalInfo` are nested JWSs.
 *
 * Every notification that carries a transaction is applied the same way:
 * the verified transaction and renewal info are the current state of that
 * subscription, so DID_RENEW extends expiry, EXPIRED leaves it in the past,
 * REFUND / REVOKE set revocation, DID_CHANGE_RENEWAL_STATUS updates
 * auto-renew, DID_FAIL_TO_RENEW / GRACE_PERIOD_EXPIRED set or clear the
 * billing grace period, and SUBSCRIBED creates or refreshes the row.
 */
export const HANDLED_TYPES = [
  "SUBSCRIBED",
  "DID_RENEW",
  "EXPIRED",
  "REFUND",
  "REVOKE",
  "DID_CHANGE_RENEWAL_STATUS",
  "DID_FAIL_TO_RENEW",
  "GRACE_PERIOD_EXPIRED",
] as const;

export interface NotificationDeps {
  db: Db;
  bundleId: string;
  proProductIds: Set<string>;
  rootCertificate?: Buffer;
  allowSandbox: boolean;
  log: Logger;
  now?: () => Date;
}

/** apple_notifications rows older than this are deleted (they only serve debugging and idempotency). */
export const NOTIFICATION_RETENTION_DAYS = 90;
/** The handler prunes at most this often per process and database. */
export const PRUNE_INTERVAL_MS = 60 * 60_000;
const lastPrune = new WeakMap<Db, number>();

export type NotificationOutcome = "applied" | "unlinked" | "ignored" | "duplicate";

const Environment = z.enum(["Production", "Sandbox", "Xcode", "LocalTesting"]);

const NotificationPayload = z.object({
  notificationType: z.string().min(1).max(64),
  subtype: z.string().max(64).optional(),
  notificationUUID: z.uuid(),
  signedDate: z.number().int().positive(),
  data: z
    .object({
      bundleId: z.string().optional(),
      environment: Environment.optional(),
      signedTransactionInfo: z.string().optional(),
      signedRenewalInfo: z.string().optional(),
    })
    .optional(),
  // Summary notifications (RENEWAL_EXTENSION) and external purchase token
  // notifications carry their bundle id here instead of in `data`.
  summary: z
    .object({
      bundleId: z.string().optional(),
      environment: Environment.optional(),
    })
    .optional(),
  externalPurchaseToken: z
    .object({
      bundleId: z.string().optional(),
      externalPurchaseId: z.string().optional(),
    })
    .optional(),
});

const Transaction = z.object({
  originalTransactionId: z.string().min(1).max(64),
  bundleId: z.string(),
  productId: z.string().min(1).max(255),
  purchaseDate: z.number().int().positive(),
  expiresDate: z.number().int().positive().optional(),
  revocationDate: z.number().int().positive().optional(),
  environment: Environment,
  appAccountToken: z.string().optional(),
  signedDate: z.number().int().positive().optional(),
});

const Renewal = z.object({
  originalTransactionId: z.string().min(1).max(64),
  autoRenewStatus: z.number().int().optional(),
  gracePeriodExpiresDate: z.number().int().positive().optional(),
  signedDate: z.number().int().positive().optional(),
});

const reject = (reason: string): never => {
  throw new HttpError(400, "invalid_notification", { reason });
};

function shape<T>(schema: z.ZodType<T>, value: unknown, reason: string): T {
  const result = schema.safeParse(value);
  return result.success ? result.data : reject(reason);
}

/**
 * Verifies and applies one notification. Returns 200-worthy outcomes for
 * every authentic payload (including duplicates, unknown transactions and
 * types we don't act on), so Apple stops retrying. Forged, malformed,
 * wrong-bundle or wrong-environment payloads are rejected with 400.
 */
export async function handleNotification(deps: NotificationDeps, signedPayload: string): Promise<NotificationOutcome> {
  if (!deps.rootCertificate) throw new HttpError(503, "purchase_verification_unavailable");
  const now = deps.now?.() ?? new Date();
  const root = deps.rootCertificate;

  const notification = shape(NotificationPayload, await verifyAppleJws(signedPayload, root, now, "invalid_notification"), "payload");
  const data = notification.data;
  // Every V2 notification names its app in data, summary or
  // externalPurchaseToken. One that names none (or another app) is rejected,
  // so a validly signed payload for a different app can't be replayed here.
  const bundleId = data?.bundleId ?? notification.summary?.bundleId ?? notification.externalPurchaseToken?.bundleId;
  if (bundleId !== deps.bundleId) reject("bundle");
  // externalPurchaseToken has no environment field; Apple prefixes sandbox ids with "SANDBOX".
  const token = notification.externalPurchaseToken;
  const environment = data?.environment ?? notification.summary?.environment
    ?? (token ? (token.externalPurchaseId?.startsWith("SANDBOX") ? "Sandbox" : "Production") : undefined);
  if (environment === undefined || (environment !== "Production" && !deps.allowSandbox)) reject("environment");

  let tx: TransactionPayload | undefined;
  let renewal: RenewalState | undefined;
  if (data?.signedTransactionInfo) {
    tx = shape(Transaction, await verifyAppleJws(data.signedTransactionInfo, root, now, "invalid_notification"), "transaction") as TransactionPayload;
    if (tx.bundleId !== deps.bundleId) reject("bundle");
    if (tx.environment !== "Production" && !deps.allowSandbox) reject("environment");
    if (data.signedRenewalInfo) {
      const info = shape(Renewal, await verifyAppleJws(data.signedRenewalInfo, root, now, "invalid_notification"), "renewal");
      if (info.originalTransactionId !== tx.originalTransactionId) reject("renewal_mismatch");
      renewal = {
        autoRenew: info.autoRenewStatus === undefined ? null : info.autoRenewStatus === 1,
        gracePeriodExpiresAt: info.gracePeriodExpiresDate ? new Date(info.gracePeriodExpiresDate) : null,
        signedAt: new Date(info.signedDate ?? notification.signedDate),
      };
    }
    // A refund or revocation of the current period ends access, even if
    // Apple's transaction info were to arrive without a revocation date
    // (upsertSubscription ignores it for an earlier period).
    if ((notification.notificationType === "REFUND" || notification.notificationType === "REVOKE") && !tx.revocationDate) {
      tx = { ...tx, revocationDate: notification.signedDate };
    }
  }

  // Only transactions for Pro products change entitlements. Notifications
  // without a transaction (TEST, summaries) are acknowledged and logged.
  const applicable = tx !== undefined && deps.proProductIds.has(tx.productId);

  const outcome = await transaction(deps.db, async (client) => {
    const inserted = await client.query(
      `insert into apple_notifications (notification_uuid, notification_type, subtype, environment, original_transaction_id, outcome, signed_at)
       values ($1, $2, $3, $4, $5, $6, $7)
       on conflict (notification_uuid) do nothing`,
      [
        notification.notificationUUID,
        notification.notificationType,
        notification.subtype ?? null,
        environment ?? null,
        tx?.originalTransactionId ?? null,
        applicable ? "applied" : "ignored",
        new Date(notification.signedDate),
      ],
    );
    if (!inserted.rowCount) return "duplicate" as const;
    if (!applicable) return "ignored" as const;

    // The app sets appAccountToken to the user id when purchasing; use it to
    // link a transaction the app never posted. Otherwise store it unlinked
    // for the app to claim via /v1/subscription/transactions.
    let userId: string | null = null;
    if (tx!.appAccountToken && z.uuid().safeParse(tx!.appAccountToken).success) {
      const { rows } = await client.query<{ id: string }>("select id from users where id = $1", [tx!.appAccountToken.toLowerCase()]);
      userId = rows[0]?.id ?? null;
    }
    const row = await upsertSubscription(client, tx!, userId, { now, renewal, forceOwner: true });
    if (tx!.revocationDate && row && !row.revoked_at) {
      // A refund of an earlier period (e.g. last month's renewal) while a
      // newer period is active: the current period stays paid for.
      deps.log.info("apple_notification_revocation_kept_current_period", {
        type: notification.notificationType,
        original_transaction_id: tx!.originalTransactionId,
      });
    }
    if (row?.user_id) return "applied" as const;
    await client.query("update apple_notifications set outcome = 'unlinked' where notification_uuid = $1", [notification.notificationUUID]);
    return "unlinked" as const;
  });

  await pruneNotifications(deps, now);
  deps.log.info("apple_notification", {
    type: notification.notificationType,
    subtype: notification.subtype,
    outcome,
    handled: (HANDLED_TYPES as readonly string[]).includes(notification.notificationType),
  });
  return outcome;
}

/**
 * Deletes apple_notifications rows past NOTIFICATION_RETENTION_DAYS, at most
 * once per PRUNE_INTERVAL_MS per process (an indexed delete on received_at).
 * Best effort: a failure is logged and never fails the notification.
 */
export async function pruneNotifications(deps: Pick<NotificationDeps, "db" | "log">, now: Date): Promise<number | null> {
  const last = lastPrune.get(deps.db);
  if (last !== undefined && now.getTime() - last < PRUNE_INTERVAL_MS) return null;
  lastPrune.set(deps.db, now.getTime());
  try {
    const cutoff = new Date(now.getTime() - NOTIFICATION_RETENTION_DAYS * 86_400_000);
    const { rowCount } = await deps.db.query(
      `delete from apple_notifications where notification_uuid in (
         select notification_uuid from apple_notifications where received_at < $1 limit 10000)`,
      [cutoff],
    );
    if (rowCount) deps.log.info("apple_notifications_pruned", { rows: rowCount });
    return rowCount ?? 0;
  } catch (error) {
    deps.log.error("apple_notifications_prune_failed", { message: error instanceof Error ? error.message : String(error) });
    return null;
  }
}
