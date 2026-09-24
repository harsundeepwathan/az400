import "server-only";
import { SignJWT, jwtVerify } from "jose";
import { cookies } from "next/headers";
import { env } from "../env";
import { withAdmin } from "../db";
import { hashPassword, verifyPassword } from "./password";
import type { AuthResult, SessionUser } from "./types";

export const LOCAL_SESSION_COOKIE = "jp_session";
const SESSION_TTL_SECONDS = 60 * 60 * 24 * 7;

function secretKey() {
  return new TextEncoder().encode(env().SESSION_SECRET);
}

async function setSession(user: SessionUser) {
  const token = await new SignJWT({ email: user.email })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(user.id)
    .setIssuedAt()
    .setExpirationTime(`${SESSION_TTL_SECONDS}s`)
    .sign(secretKey());
  (await cookies()).set(LOCAL_SESSION_COOKIE, token, {
    httpOnly: true,
    sameSite: "lax",
    secure: env().NODE_ENV === "production",
    path: "/",
    maxAge: SESSION_TTL_SECONDS,
  });
}

export async function localGetUser(): Promise<SessionUser | null> {
  const token = (await cookies()).get(LOCAL_SESSION_COOKIE)?.value;
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, secretKey(), { algorithms: ["HS256"] });
    if (!payload.sub) return null;
    // Confirm the account still exists (it may have been deleted).
    const row = await withAdmin((db) =>
      db.one<{ id: string; email: string }>("select id, email from auth.users where id = $1", [payload.sub]),
    );
    return row ? { id: row.id, email: row.email } : null;
  } catch {
    return null;
  }
}

export async function localSignIn(email: string, password: string): Promise<AuthResult> {
  const row = await withAdmin((db) =>
    db.one<{ id: string; email: string; encrypted_password: string | null }>(
      "select id, email, encrypted_password from auth.users where lower(email) = lower($1)",
      [email],
    ),
  );
  // Always run a hash comparison to avoid leaking which emails exist via timing.
  const ok = await verifyPassword(password, row?.encrypted_password ?? "scrypt$16384$8$1$AAAA$AAAA");
  if (!row || !ok) return { ok: false, error: "Incorrect email or password." };
  await setSession({ id: row.id, email: row.email });
  return { ok: true };
}

export async function localSignUp(email: string, password: string): Promise<AuthResult> {
  const hash = await hashPassword(password);
  const created = await withAdmin((db) =>
    db.one<{ id: string; email: string }>(
      "insert into auth.users (email, encrypted_password) values (lower($1), $2) on conflict (email) do nothing returning id, email",
      [email, hash],
    ),
  );
  if (!created) return { ok: false, error: "An account with this email already exists. Try signing in." };
  await setSession(created);
  return { ok: true };
}

export async function localSignOut() {
  (await cookies()).delete(LOCAL_SESSION_COOKIE);
}

export async function localDeleteUser(userId: string) {
  await withAdmin((db) => db.query("delete from auth.users where id = $1", [userId]));
  await localSignOut();
}
