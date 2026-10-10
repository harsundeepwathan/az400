import type { FastifyInstance } from 'fastify';
import pg from 'pg';
import { buildApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { createPool } from '../src/db.js';
import type { ControlClient } from '../src/lib/control.js';
import { hashPassword } from '../src/lib/passwords.js';

export const KEKS = 'v1:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
export const PASSWORD = 'correct horse battery staple';

export interface World {
  app: FastifyInstance;
  admin: pg.Pool; // superuser pool for fixtures and assertions (bypasses RLS)
  orgA: string;
  orgB: string;
  users: Record<string, string>;
  close: () => Promise<void>;
}

export const fakeControl: ControlClient = {
  validate: async () => ({ ok: true, report: { ok: true, checks: [{ check: 'stub', ok: true }] } }),
  discover: async () => ({ ok: true, resources: [] }),
  testChannel: async () => ({ ok: true }),
  providers: async () => ({}),
};

export async function world(): Promise<World> {
  const admin = new pg.Pool({ connectionString: process.env.TEST_ADMIN_DB_URL });
  const suffix = Math.random().toString(36).slice(2, 8);
  const org = async (slug: string) =>
    (await admin.query(`INSERT INTO organizations(name, slug) VALUES ($1,$2) RETURNING id`, [slug, `${slug}-${suffix}`])).rows[0].id as string;
  const orgA = await org('alpha');
  const orgB = await org('bravo');
  for (const o of [orgA, orgB]) await admin.query(`SELECT skywatch_init_org($1)`, [o]);
  const hash = await hashPassword(PASSWORD);
  const users: Record<string, string> = {};
  for (const [key, orgId, role] of [
    ['adminA', orgA, 'org_admin'], ['infraA', orgA, 'infra_admin'], ['operatorA', orgA, 'operator'], ['viewerA', orgA, 'viewer'],
    ['adminB', orgB, 'org_admin'],
  ] as const) {
    const email = `${key}-${suffix}@test.local`;
    const id = (await admin.query(`INSERT INTO users(email, display_name, password_hash) VALUES ($1,$2,$3) RETURNING id`, [email, key, hash])).rows[0].id;
    await admin.query(`INSERT INTO memberships(org_id, user_id, role) VALUES ($1,$2,$3)`, [orgId, id, role]);
    users[key] = email;
  }
  const cfg = loadConfig({ ...process.env, SKYWATCH_KEKS: KEKS, NODE_ENV: 'test' });
  const db = createPool(cfg.databaseUrl);
  const app = await buildApp(cfg, db, { control: fakeControl });
  return { app, admin, orgA, orgB, users, close: async () => { await app.close(); await db.end(); await admin.end(); } };
}

export interface Session {
  cookie: string;
  csrf: string;
  get: (url: string) => Promise<any>;
  send: (method: string, url: string, body?: unknown, opts?: { csrf?: string | null }) => Promise<any>;
}

export async function login(app: FastifyInstance, email: string): Promise<Session> {
  const res = await app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email, password: PASSWORD } });
  if (res.statusCode !== 200) throw new Error(`login failed ${res.statusCode} ${res.body}`);
  const cookie = String(res.headers['set-cookie']).split(';')[0]!;
  const csrf = res.json().csrf_token as string;
  const send = (method: string, url: string, body?: unknown, opts: { csrf?: string | null } = {}) =>
    app.inject({
      method: method as any, url, payload: body as any,
      headers: { cookie, ...(opts.csrf === null ? {} : { 'x-csrf-token': opts.csrf ?? csrf }) },
    });
  return { cookie, csrf, get: (url) => app.inject({ method: 'GET', url, headers: { cookie } }), send };
}
