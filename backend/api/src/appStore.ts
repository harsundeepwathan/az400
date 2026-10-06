import { X509Certificate } from "node:crypto";
import { compactVerify, decodeProtectedHeader, importX509 } from "jose";
import type { Db } from "./db.js";
import { HttpError } from "./http.js";

/** Apple marks its App Store receipt-signing certificates with these extension OIDs. */
const LEAF_OID = Buffer.from([0x06, 0x0a, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x0b, 0x01]); // 1.2.840.113635.100.6.11.1
const INTERMEDIATE_OID = Buffer.from([0x06, 0x0a, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x02, 0x01]); // 1.2.840.113635.100.6.2.1

/** The fields of a StoreKit 2 `JWSTransactionDecodedPayload` that matter here. */
export interface TransactionPayload {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  purchaseDate: number;
  expiresDate?: number;
  revocationDate?: number;
  environment: "Production" | "Sandbox" | "Xcode" | "LocalTesting";
  appAccountToken?: string;
  type?: string;
}

export interface StoreKitDeps {
  db: Db;
  bundleId: string;
  proProductIds: Set<string>;
  rootCertificate?: Buffer;
  allowSandbox: boolean;
  now?: () => Date;
}

function toCertificate(base64Der: string): X509Certificate {
  return new X509Certificate(Buffer.from(base64Der, "base64"));
}

/**
 * Verifies a StoreKit 2 signed transaction (`Transaction.jwsRepresentation`):
 * the x5c chain must end in the configured Apple Root CA G3, each certificate
 * must be valid at the signing date and signed by the next, the leaf and
 * intermediate must carry Apple's marker extensions, and the JWS signature
 * must verify with the leaf key.
 */
export async function verifySignedTransaction(jws: string, root: Buffer, now: Date): Promise<TransactionPayload> {
  const fail = (reason: string): never => {
    throw new HttpError(400, "invalid_transaction", { reason });
  };
  let header: ReturnType<typeof decodeProtectedHeader>;
  try {
    header = decodeProtectedHeader(jws);
  } catch {
    return fail("malformed");
  }
  if (header.alg !== "ES256") fail("algorithm");
  const chain = header.x5c;
  if (!Array.isArray(chain) || chain.length !== 3) fail("certificate_chain");
  let leaf: X509Certificate, intermediate: X509Certificate, presentedRoot: X509Certificate, trustedRoot: X509Certificate;
  try {
    [leaf, intermediate, presentedRoot] = chain!.map(toCertificate);
    trustedRoot = new X509Certificate(root);
  } catch {
    return fail("certificate_parse");
  }
  if (!presentedRoot.raw.equals(trustedRoot.raw)) fail("untrusted_root");
  if (!leaf.verify(intermediate.publicKey) || !intermediate.verify(trustedRoot.publicKey)) fail("certificate_signature");
  if (!leaf.raw.includes(LEAF_OID) || !intermediate.raw.includes(INTERMEDIATE_OID)) fail("certificate_purpose");

  let payload: TransactionPayload;
  try {
    const key = await importX509(leaf.toString(), "ES256");
    const { payload: bytes } = await compactVerify(jws, key);
    payload = JSON.parse(new TextDecoder().decode(bytes)) as TransactionPayload;
  } catch {
    return fail("signature");
  }
  // Certificates must have been valid when Apple signed, and must not be from the future.
  const signedAt = new Date((payload as { signedDate?: number }).signedDate ?? now.getTime());
  for (const cert of [leaf, intermediate, trustedRoot]) {
    if (signedAt < new Date(cert.validFrom) || signedAt > new Date(cert.validTo)) fail("certificate_expired");
  }
  return payload;
}

export interface Entitlement {
  tier: "free" | "pro";
  product_id?: string;
  expires_at?: string;
}

/** Verifies a purchase, binds it to the user and returns their entitlement. */
export async function recordTransaction(deps: StoreKitDeps, userId: string, jws: string): Promise<Entitlement> {
  if (!deps.rootCertificate) throw new HttpError(503, "purchase_verification_unavailable");
  const now = deps.now?.() ?? new Date();
  const tx = await verifySignedTransaction(jws, deps.rootCertificate, now);

  if (tx.bundleId !== deps.bundleId) throw new HttpError(400, "invalid_transaction", { reason: "bundle" });
  if (!deps.proProductIds.has(tx.productId)) throw new HttpError(400, "invalid_transaction", { reason: "product" });
  if (tx.environment !== "Production" && !deps.allowSandbox) throw new HttpError(400, "invalid_transaction", { reason: "environment" });
  // The app sets appAccountToken to the user id when purchasing, so a
  // transaction can't be replayed onto another account.
  if (tx.appAccountToken && tx.appAccountToken.toLowerCase() !== userId.toLowerCase()) {
    throw new HttpError(403, "transaction_belongs_to_another_account");
  }

  const { rows } = await deps.db.query<{ user_id: string }>(
    `insert into subscriptions (original_transaction_id, user_id, product_id, environment, purchased_at, expires_at, revoked_at, updated_at)
     values ($1, $2, $3, $4, $5, $6, $7, now())
     on conflict (original_transaction_id) do update set
       product_id = excluded.product_id,
       expires_at = greatest(subscriptions.expires_at, excluded.expires_at),
       revoked_at = excluded.revoked_at,
       updated_at = now()
     where subscriptions.user_id = excluded.user_id
     returning user_id`,
    [
      tx.originalTransactionId,
      userId,
      tx.productId,
      tx.environment,
      new Date(tx.purchaseDate),
      tx.expiresDate ? new Date(tx.expiresDate) : null,
      tx.revocationDate ? new Date(tx.revocationDate) : null,
    ],
  );
  if (rows.length === 0) throw new HttpError(403, "transaction_belongs_to_another_account");
  return entitlement(deps.db, userId, now);
}

/** Pro while any verified, unrevoked subscription is unexpired (or non-expiring). */
export async function entitlement(db: Db, userId: string, now = new Date()): Promise<Entitlement> {
  const { rows } = await db.query<{ product_id: string; expires_at: Date | null }>(
    `select product_id, expires_at from subscriptions
     where user_id = $1 and revoked_at is null and (expires_at is null or expires_at > $2)
     order by expires_at desc nulls first limit 1`,
    [userId, now],
  );
  const active = rows[0];
  if (!active) return { tier: "free" };
  return { tier: "pro", product_id: active.product_id, expires_at: active.expires_at?.toISOString() };
}
