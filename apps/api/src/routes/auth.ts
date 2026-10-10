import type { FastifyPluginAsync } from 'fastify';
import * as oidc from 'openid-client';
import { z } from 'zod';
import { permissionsFor, type Role } from '../auth/rbac.js';
import { createSession, requireAuth, SESSION_COOKIE, setSessionCookie } from '../auth/session.js';
import { withScope } from '../db.js';
import { audit } from '../lib/audit.js';
import { HttpError, badRequest } from '../lib/errors.js';
import { body } from '../lib/http.js';
import { verifyPassword } from '../lib/passwords.js';

const OIDC_COOKIE = 'sw_oidc';

const routes: FastifyPluginAsync = async (app) => {
  const { cfg, db } = app.deps;
  let oidcConfig: Promise<oidc.Configuration> | undefined;
  const getOidc = () => {
    if (!cfg.oidc) throw new HttpError(404, 'Single sign-on is not configured', 'oidc_disabled');
    oidcConfig ??= oidc.discovery(new URL(cfg.oidc.issuer), cfg.oidc.clientId, cfg.oidc.clientSecret);
    return oidcConfig;
  };

  async function me(userId: string, orgId: string | null, csrf: string) {
    const { rows: orgs } = await db.query(`SELECT org_id, name, slug, is_demo, role FROM skywatch_user_orgs($1)`, [userId]);
    const user = await withScope(db, { orgId: null, userId }, async (tx) =>
      (await tx.query(`SELECT id, email, display_name FROM users WHERE id=$1`, [userId])).rows[0],
    );
    const active = orgs.find((o) => o.org_id === orgId);
    return {
      user,
      csrf_token: csrf,
      organizations: orgs.map((o) => ({ id: o.org_id, name: o.name, slug: o.slug, is_demo: o.is_demo, role: o.role })),
      active_org: active ? { id: active.org_id, name: active.name, slug: active.slug, is_demo: active.is_demo } : null,
      role: active?.role ?? null,
      permissions: active ? permissionsFor(active.role as Role) : [],
    };
  }

  app.get('/auth/config', async () => ({ local_login: cfg.localLogin, oidc: !!cfg.oidc }));

  app.post('/auth/login', { config: { rateLimit: { max: 10, timeWindow: '1 minute' } } }, async (req, reply) => {
    if (!cfg.localLogin) throw new HttpError(404, 'Password sign-in is disabled; use single sign-on', 'local_login_disabled');
    const b = body(req, z.object({ email: z.string().email().max(254), password: z.string().min(1).max(200) }));
    const { rows } = await db.query(`SELECT id, password_hash, disabled FROM skywatch_login_lookup($1)`, [b.email]);
    const u = rows[0];
    const ok = await verifyPassword(b.password, u?.password_hash ?? null);
    if (!u || !ok || u.disabled) throw new HttpError(401, 'Invalid email or password', 'invalid_credentials');
    const { rows: orgs } = await db.query(`SELECT org_id FROM skywatch_user_orgs($1)`, [u.id]);
    const orgId: string | null = orgs[0]?.org_id ?? null;
    const s = await createSession(db, u.id, orgId, cfg.sessionTtlHours, req.ip, req.headers['user-agent'] ?? '');
    if (orgId) {
      await withScope(db, { orgId, userId: u.id }, async (tx) => {
        await tx.query(`UPDATE users SET last_login_at=now() WHERE id=$1`, [u.id]);
        await audit(tx, { orgId, userId: u.id, action: 'auth.login', details: { method: 'password' }, ip: req.ip });
      });
    }
    setSessionCookie(reply, s.token, cfg.production, cfg.sessionTtlHours);
    return me(u.id, orgId, s.csrf);
  });

  app.post('/auth/logout', async (req, reply) => {
    const p = req.principal;
    if (p) await withScope(db, { orgId: null, userId: p.userId }, (tx) => tx.query(`DELETE FROM sessions WHERE token_hash=$1`, [p.tokenHash]));
    reply.clearCookie(SESSION_COOKIE, { path: '/' });
    return { ok: true };
  });

  // --- OIDC (authorization code + PKCE). MFA is enforced by the identity provider. ---
  app.get('/auth/oidc/start', async (_req, reply) => {
    const conf = await getOidc();
    const verifier = oidc.randomPKCECodeVerifier();
    const state = oidc.randomState();
    const nonce = oidc.randomNonce();
    const url = oidc.buildAuthorizationUrl(conf, {
      redirect_uri: `${cfg.publicUrl}/api/v1/auth/oidc/callback`,
      scope: cfg.oidc!.scopes,
      code_challenge: await oidc.calculatePKCECodeChallenge(verifier),
      code_challenge_method: 'S256',
      state,
      nonce,
    });
    reply.setCookie(OIDC_COOKIE, JSON.stringify({ verifier, state, nonce }), {
      httpOnly: true, secure: cfg.production, sameSite: 'lax', path: '/api/v1/auth/oidc', maxAge: 600, signed: !!process.env.SKYWATCH_COOKIE_SECRET,
    });
    return reply.redirect(url.href);
  });

  app.get('/auth/oidc/callback', async (req, reply) => {
    const conf = await getOidc();
    const raw = req.cookies[OIDC_COOKIE];
    if (!raw) throw badRequest('Sign-in session expired; start again');
    const unsigned = process.env.SKYWATCH_COOKIE_SECRET ? req.unsignCookie(raw) : { valid: true, value: raw };
    if (!unsigned.valid || !unsigned.value) throw badRequest('Invalid sign-in state');
    const st = JSON.parse(unsigned.value) as { verifier: string; state: string; nonce: string };
    const tokens = await oidc.authorizationCodeGrant(conf, new URL(`${cfg.publicUrl}${req.url}`), {
      pkceCodeVerifier: st.verifier, expectedState: st.state, expectedNonce: st.nonce,
    });
    const claims = tokens.claims();
    if (!claims?.sub) throw badRequest('Identity provider returned no subject');
    const email = typeof claims.email === 'string' ? claims.email : '';
    if (claims.email_verified === false) throw new HttpError(403, 'Email address is not verified at the identity provider', 'unverified');
    const { rows } = await db.query(`SELECT id, disabled, linked FROM skywatch_oidc_lookup($1,$2,$3)`, [claims.iss, claims.sub, email]);
    const u = rows[0];
    // Users must be invited (pre-provisioned by email) before first SSO sign-in.
    if (!u || u.disabled) throw new HttpError(403, 'Your account has not been invited to Skywatch', 'not_invited');
    if (!u.linked) {
      await withScope(db, { orgId: null, userId: u.id }, (tx) =>
        tx.query(`UPDATE users SET oidc_issuer=$2, oidc_subject=$3 WHERE id=$1`, [u.id, claims.iss, claims.sub]),
      );
    }
    const { rows: orgs } = await db.query(`SELECT org_id FROM skywatch_user_orgs($1)`, [u.id]);
    const orgId: string | null = orgs[0]?.org_id ?? null;
    const s = await createSession(db, u.id, orgId, cfg.sessionTtlHours, req.ip, req.headers['user-agent'] ?? '');
    if (orgId) {
      await withScope(db, { orgId, userId: u.id }, (tx) =>
        audit(tx, { orgId, userId: u.id, action: 'auth.login', details: { method: 'oidc', issuer: claims.iss }, ip: req.ip }),
      );
    }
    reply.clearCookie(OIDC_COOKIE, { path: '/api/v1/auth/oidc' });
    setSessionCookie(reply, s.token, cfg.production, cfg.sessionTtlHours);
    return reply.redirect(cfg.publicUrl + '/');
  });

  app.get('/me', async (req) => {
    const p = requireAuth(req);
    return me(p.userId, p.orgId, p.csrf);
  });

  app.post('/me/org', async (req) => {
    const p = requireAuth(req);
    const b = body(req, z.object({ org_id: z.string().uuid() }));
    const { rows } = await db.query(`SELECT 1 FROM skywatch_user_orgs($1) WHERE org_id=$2`, [p.userId, b.org_id]);
    if (!rows[0]) throw new HttpError(403, 'You are not a member of that organization', 'forbidden');
    await withScope(db, { orgId: null, userId: p.userId }, (tx) =>
      tx.query(`UPDATE sessions SET org_id=$2 WHERE token_hash=$1`, [p.tokenHash, b.org_id]),
    );
    return me(p.userId, b.org_id, p.csrf);
  });

  app.post('/orgs', async (req) => {
    const p = requireAuth(req);
    const b = body(req, z.object({
      name: z.string().trim().min(2).max(200),
      slug: z.string().regex(/^[a-z0-9][a-z0-9-]{1,62}$/),
    }));
    const id = crypto.randomUUID();
    await withScope(db, { orgId: id, userId: p.userId }, async (tx) => {
      await tx.query(`INSERT INTO organizations(id, name, slug) VALUES ($1,$2,$3)`, [id, b.name, b.slug]);
      await tx.query(`INSERT INTO memberships(org_id, user_id, role) VALUES ($1,$2,'org_admin')`, [id, p.userId]);
      await tx.query(`SELECT skywatch_init_org($1)`, [id]);
      await audit(tx, { orgId: id, userId: p.userId, action: 'org.created', targetType: 'organization', targetId: id, ip: req.ip });
      await tx.query(`UPDATE sessions SET org_id=$2 WHERE token_hash=$1`, [p.tokenHash, id]);
    });
    return me(p.userId, id, p.csrf);
  });
};

export default routes;
