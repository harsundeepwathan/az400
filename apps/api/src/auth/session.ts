import type { FastifyReply, FastifyRequest } from 'fastify';
import type { Db } from '../db.js';
import { withScope } from '../db.js';
import { HttpError, forbidden } from '../lib/errors.js';
import { randomToken, sha256 } from '../lib/tokens.js';
import { can, type Permission, type Role } from './rbac.js';

export const SESSION_COOKIE = 'sw_session';

export interface Principal {
  userId: string;
  orgId: string | null;
  role?: Role;
  csrf: string;
  tokenHash: Buffer;
}

declare module 'fastify' {
  interface FastifyRequest {
    principal?: Principal;
  }
}

export async function createSession(db: Db, userId: string, orgId: string | null, ttlHours: number, ip: string, ua: string) {
  const token = randomToken(32);
  const csrf = randomToken(24);
  await withScope(db, { orgId: null, userId }, (tx) =>
    tx.query(
      `INSERT INTO sessions(token_hash, user_id, org_id, csrf_token, expires_at, ip, user_agent)
       VALUES ($1,$2,$3,$4, now() + make_interval(hours => $5), $6, left($7, 300))`,
      [sha256(token), userId, orgId, csrf, ttlHours, ip, ua],
    ),
  );
  return { token, csrf };
}

/** Resolves the session cookie into a principal (user, active org, role). */
export async function loadPrincipal(db: Db, req: FastifyRequest): Promise<Principal | undefined> {
  const token = req.cookies[SESSION_COOKIE];
  if (!token) return undefined;
  const hash = sha256(token);
  const { rows } = await db.query(`SELECT user_id, org_id, csrf_token FROM skywatch_session_lookup($1)`, [hash]);
  const s = rows[0];
  if (!s) return undefined;
  const p: Principal = { userId: s.user_id, orgId: s.org_id, csrf: s.csrf_token, tokenHash: hash };
  if (p.orgId) {
    const { rows: m } = await db.query(`SELECT role FROM skywatch_user_orgs($1) WHERE org_id = $2`, [p.userId, p.orgId]);
    if (m[0]) p.role = m[0].role as Role;
    else p.orgId = null; // membership removed since login
  }
  // Disabled users lose access immediately.
  const { rows: u } = await withScope(db, { orgId: null, userId: p.userId }, (tx) =>
    tx.query(`SELECT disabled FROM users WHERE id=$1`, [p.userId]),
  );
  if (!u[0] || u[0].disabled) return undefined;
  return p;
}

const SAFE = new Set(['GET', 'HEAD', 'OPTIONS']);

/** CSRF: state-changing requests must echo the session's CSRF token in a header. */
export function checkCsrf(req: FastifyRequest) {
  if (SAFE.has(req.method) || !req.principal) return;
  const sent = req.headers['x-csrf-token'];
  if (typeof sent !== 'string' || sent !== req.principal.csrf) {
    throw new HttpError(403, 'Missing or invalid CSRF token', 'csrf');
  }
}

export function requireAuth(req: FastifyRequest): Principal {
  if (!req.principal) throw new HttpError(401, 'Authentication required', 'unauthenticated');
  return req.principal;
}

/** Requires an active organization and a permission; returns the tenant scope. */
export function requirePerm(req: FastifyRequest, perm: Permission) {
  const p = requireAuth(req);
  if (!p.orgId || !p.role) throw new HttpError(409, 'Select an organization first', 'no_org');
  if (!can(p.role, perm)) throw forbidden(`Your role (${p.role}) does not allow this action`);
  return { orgId: p.orgId, userId: p.userId, role: p.role };
}

export function setSessionCookie(reply: FastifyReply, token: string, secure: boolean, ttlHours: number) {
  reply.setCookie(SESSION_COOKIE, token, {
    httpOnly: true,
    secure,
    sameSite: 'lax',
    path: '/',
    maxAge: ttlHours * 3600,
  });
}
