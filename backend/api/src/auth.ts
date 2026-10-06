import { createHash, randomBytes, randomUUID } from "node:crypto";
import { createRemoteJWKSet, jwtVerify, SignJWT, type JWTVerifyGetKey } from "jose";
import type { Db } from "./db.js";
import { transaction } from "./db.js";
import { HttpError, type Request } from "./http.js";

const ACCESS_TOKEN_TTL_SECONDS = 60 * 60;
const REFRESH_TOKEN_TTL_DAYS = 60;
const ISSUER = "vector-api";
const AUDIENCE = "vector-ios";

export const APPLE_ISSUER = "https://appleid.apple.com";
export const appleKeys = (): JWTVerifyGetKey => createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

export interface Session {
  access_token: string;
  expires_in: number;
  refresh_token: string;
  user_id: string;
}

export interface AuthDeps {
  db: Db;
  jwtSecret: Uint8Array;
  bundleId: string;
  appleKeys: JWTVerifyGetKey;
  now?: () => Date;
}

const sha256 = (value: string | Buffer) => createHash("sha256").update(value).digest();

/**
 * Verifies a Sign in with Apple identity token (signature, issuer, audience,
 * expiry and, when the app sent one, the nonce) and returns the stable user id.
 */
export async function verifyAppleIdentity(deps: AuthDeps, identityToken: string, nonce?: string): Promise<string> {
  try {
    const { payload } = await jwtVerify(identityToken, deps.appleKeys, {
      issuer: APPLE_ISSUER,
      audience: deps.bundleId,
      currentDate: deps.now?.(),
    });
    if (typeof payload.sub !== "string" || payload.sub.length === 0) throw new Error("missing sub");
    if (nonce !== undefined) {
      // The app sends the raw nonce; Apple embeds its SHA-256 hex.
      const expected = sha256(nonce).toString("hex");
      if (payload.nonce !== expected) throw new Error("nonce mismatch");
    }
    return payload.sub;
  } catch {
    throw new HttpError(401, "invalid_identity_token");
  }
}

async function issueSession(deps: AuthDeps, client: { query: Db["query"] }, userId: string, familyId: string): Promise<Session> {
  const now = deps.now?.() ?? new Date();
  const refreshToken = randomBytes(32).toString("base64url");
  const expires = new Date(now.getTime() + REFRESH_TOKEN_TTL_DAYS * 86_400_000);
  await client.query(
    "insert into refresh_tokens (user_id, family_id, token_hash, created_at, expires_at) values ($1, $2, $3, $4, $5)",
    [userId, familyId, sha256(refreshToken), now, expires],
  );
  const accessToken = await new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt(Math.floor(now.getTime() / 1000))
    .setExpirationTime(Math.floor(now.getTime() / 1000) + ACCESS_TOKEN_TTL_SECONDS)
    .sign(deps.jwtSecret);
  return { access_token: accessToken, expires_in: ACCESS_TOKEN_TTL_SECONDS, refresh_token: refreshToken, user_id: userId };
}

/** Sign in (or sign up) with Apple. Creates the user on first sign-in. */
export async function signInWithApple(deps: AuthDeps, identityToken: string, nonce?: string): Promise<Session> {
  const appleSub = await verifyAppleIdentity(deps, identityToken, nonce);
  return transaction(deps.db, async (client) => {
    const { rows } = await client.query<{ id: string }>(
      `insert into users (apple_sub) values ($1)
       on conflict (apple_sub) do update set last_seen_at = now()
       returning id`,
      [appleSub],
    );
    return issueSession(deps, client, rows[0].id, randomUUID());
  });
}

/**
 * Exchanges a refresh token for a new session and retires the old token.
 * Presenting an already-rotated token means it leaked: the whole family is revoked.
 */
export async function refreshSession(deps: AuthDeps, refreshToken: string): Promise<Session> {
  const now = deps.now?.() ?? new Date();
  const outcome = await transaction(deps.db, async (client) => {
    const { rows } = await client.query<{ id: string; user_id: string; family_id: string; expires_at: Date; revoked_at: Date | null }>(
      "select id, user_id, family_id, expires_at, revoked_at from refresh_tokens where token_hash = $1 for update",
      [sha256(refreshToken)],
    );
    const token = rows[0];
    if (!token) return { ok: false, error: "invalid_refresh_token" } as const;
    if (token.revoked_at) {
      await client.query("update refresh_tokens set revoked_at = coalesce(revoked_at, $2) where family_id = $1", [token.family_id, now]);
      return { ok: false, error: "refresh_token_reused" } as const;
    }
    if (token.expires_at <= now) return { ok: false, error: "refresh_token_expired" } as const;
    await client.query("update refresh_tokens set revoked_at = $2 where id = $1", [token.id, now]);
    await client.query("update users set last_seen_at = $2 where id = $1", [token.user_id, now]);
    return { ok: true, session: await issueSession(deps, client, token.user_id, token.family_id) } as const;
  });
  // Committed outside the failing path so a reuse revocation sticks.
  if (!outcome.ok) throw new HttpError(401, outcome.error);
  return outcome.session;
}

/** Revokes every refresh token for the user (sign out everywhere). */
export async function signOut(db: Db, userId: string) {
  await db.query("update refresh_tokens set revoked_at = now() where user_id = $1 and revoked_at is null", [userId]);
}

/** Resolves the bearer token to a user id, or throws 401. */
export async function authenticate(deps: Pick<AuthDeps, "db" | "jwtSecret" | "now">, req: Request): Promise<string> {
  const header = String(req.headers.authorization ?? "");
  const token = /^Bearer (.+)$/.exec(header)?.[1];
  if (!token) throw new HttpError(401, "missing_token");
  let userId: string;
  try {
    const { payload } = await jwtVerify(token, deps.jwtSecret, {
      issuer: ISSUER,
      audience: AUDIENCE,
      algorithms: ["HS256"],
      currentDate: deps.now?.(),
    });
    if (typeof payload.sub !== "string") throw new Error("no sub");
    userId = payload.sub;
  } catch {
    throw new HttpError(401, "invalid_token");
  }
  // A deleted account's still-valid access token must stop working immediately.
  const { rowCount } = await deps.db.query("select 1 from users where id = $1", [userId]);
  if (!rowCount) throw new HttpError(401, "invalid_token");
  req.userId = userId;
  return userId;
}
