import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withScope, createPool } from '../src/db.js';
import { open, parseKeyring } from '../src/lib/envelope.js';
import { KEKS, login, type Session, type World, world } from './helpers.js';

let w: World;
let adminA: Session, infraA: Session, operatorA: Session, viewerA: Session, adminB: Session;
let resA: string, resB: string, incA: string;

beforeAll(async () => {
  w = await world();
  [adminA, infraA, operatorA, viewerA, adminB] = await Promise.all(
    ['adminA', 'infraA', 'operatorA', 'viewerA', 'adminB'].map((k) => login(w.app, w.users[k]!)),
  );
  const mk = async (org: string, name: string) =>
    (await w.admin.query(`INSERT INTO resources(org_id, provider, provider_resource_id, name, resource_type, power_state, operational_state)
      VALUES ($1,'azure',$2,$3,'vm','running','critical') RETURNING id`, [org, '/vm/' + name, name])).rows[0].id as string;
  resA = await mk(w.orgA, 'alpha-web-01');
  resB = await mk(w.orgB, 'bravo-secret-db');
  incA = (await w.admin.query(`INSERT INTO incidents(org_id, title, severity, resource_id, dedup_key, trigger_summary, first_detected_at, last_observed_at)
    VALUES ($1,'alpha-web-01: Disk space critical','critical',$2,'resource:x','Disk / at 95%', now() - interval '10 minutes', now()) RETURNING id`,
  [w.orgA, resA])).rows[0].id;
  await w.admin.query(`INSERT INTO incidents(org_id, title, severity, resource_id, dedup_key, trigger_summary, first_detected_at, last_observed_at)
    VALUES ($1,'bravo incident','critical',$2,'resource:y','x', now(), now())`, [w.orgB, resB]);
  await w.admin.query(`INSERT INTO metric_latest(org_id, resource_id, metric, series, ts, value, source) VALUES
    ($1,$2,'cpu.utilization','',now(),42,'agent'), ($1,$2,'disk.utilization','mount=/',now(),95,'agent')`, [w.orgA, resA]);
});
afterAll(async () => w?.close());

describe('authentication', () => {
  it('rejects bad passwords without revealing whether the user exists', async () => {
    const bad = await w.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: w.users.adminA, password: 'wrong' } });
    const unknown = await w.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: 'nobody@test.local', password: 'wrong' } });
    expect(bad.statusCode).toBe(401);
    expect(unknown.statusCode).toBe(401);
    expect(bad.json().message).toBe(unknown.json().message);
  });
  it('requires a session', async () => {
    expect((await w.app.inject({ method: 'GET', url: '/api/v1/resources' })).statusCode).toBe(401);
  });
  it('sets an httpOnly session cookie and returns role-derived permissions', async () => {
    const res = await w.app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: { email: w.users.viewerA, password: 'correct horse battery staple' } });
    expect(String(res.headers['set-cookie'])).toMatch(/HttpOnly/i);
    expect(res.json().permissions).toEqual(['read']);
  });
  it('enforces CSRF on state-changing requests', async () => {
    const r = await operatorA.send('POST', `/api/v1/incidents/${incA}/comment`, { note: 'x' }, { csrf: null });
    expect(r.statusCode).toBe(403);
    expect(r.json().error).toBe('csrf');
  });
});

describe('tenant isolation', () => {
  it('lists only the active organization data', async () => {
    const a = (await adminA.get('/api/v1/resources')).json();
    expect(a.items.map((r: any) => r.name)).toEqual(['alpha-web-01']);
    const b = (await adminB.get('/api/v1/resources')).json();
    expect(b.items.map((r: any) => r.name)).toEqual(['bravo-secret-db']);
  });
  it('returns 404 for another tenant object accessed by id', async () => {
    expect((await adminA.get(`/api/v1/resources/${resB}`)).statusCode).toBe(404);
    expect((await adminB.get(`/api/v1/incidents/${incA}`)).statusCode).toBe(404);
    const ack = await adminB.send('POST', `/api/v1/incidents/${incA}/ack`, {});
    expect(ack.statusCode).toBe(404);
  });
  it('cannot switch into an organization without membership', async () => {
    expect((await adminA.send('POST', '/api/v1/me/org', { org_id: w.orgB })).statusCode).toBe(403);
  });
  it('is enforced by row-level security even for raw queries', async () => {
    const db = createPool(process.env.SKYWATCH_API_DATABASE_URL!);
    try {
      const rows = await withScope(db, { orgId: w.orgA, userId: null }, async (tx) => (await tx.query(`SELECT name FROM resources`)).rows);
      expect(rows.map((r) => r.name)).toEqual(['alpha-web-01']);
      const none = await withScope(db, { orgId: null, userId: null }, async (tx) => (await tx.query(`SELECT count(*)::int AS n FROM resources`)).rows[0].n);
      expect(none).toBe(0);
      const users = await withScope(db, { orgId: w.orgA, userId: null }, async (tx) => (await tx.query(`SELECT email FROM users`)).rows);
      expect(users.some((u) => u.email === w.users.adminB)).toBe(false);
      await expect(withScope(db, { orgId: w.orgA, userId: null }, (tx) =>
        tx.query(`INSERT INTO resources(org_id, provider, provider_resource_id, name, resource_type) VALUES ($1,'azure','x','x','vm')`, [w.orgB]),
      )).rejects.toThrow(/row-level security/);
    } finally {
      await db.end();
    }
  });
});

describe('role-based access control', () => {
  const rule = { name: 'Test rule', kind: 'metric_threshold', metric: 'cpu.utilization', operator: '>', threshold: 90, recovery_threshold: 85, severity: 'warning' };
  it('viewer is read-only', async () => {
    expect((await viewerA.send('POST', '/api/v1/alert-rules', rule)).statusCode).toBe(403);
    expect((await viewerA.send('POST', `/api/v1/incidents/${incA}/ack`, {})).statusCode).toBe(403);
    expect((await viewerA.get('/api/v1/audit-logs')).statusCode).toBe(403);
  });
  it('operator can work incidents but not configure monitoring', async () => {
    expect((await operatorA.send('POST', '/api/v1/alert-rules', rule)).statusCode).toBe(403);
    expect((await operatorA.send('POST', '/api/v1/accounts', {})).statusCode).toBe(403);
  });
  it('infra admin can configure rules; validation rejects bad hysteresis', async () => {
    const ok = await infraA.send('POST', '/api/v1/alert-rules', rule);
    expect(ok.statusCode).toBe(200);
    const bad = await infraA.send('POST', '/api/v1/alert-rules', { ...rule, recovery_threshold: 95 });
    expect(bad.statusCode).toBe(400);
    expect(JSON.stringify(bad.json().issues)).toMatch(/hysteresis/);
    expect((await infraA.send('POST', '/api/v1/members', { email: 'x@y.z', display_name: 'X', role: 'viewer' })).statusCode).toBe(403);
  });
});

describe('incident workflow', () => {
  it('acknowledges, comments and records the timeline and audit trail', async () => {
    expect((await operatorA.send('POST', `/api/v1/incidents/${incA}/ack`, { note: 'looking' })).statusCode).toBe(200);
    expect((await operatorA.send('POST', `/api/v1/incidents/${incA}/ack`, {})).statusCode).toBe(400);
    expect((await operatorA.send('POST', `/api/v1/incidents/${incA}/comment`, { note: 'Disk cleanup started' })).statusCode).toBe(200);
    const d = (await viewerA.get(`/api/v1/incidents/${incA}`)).json();
    expect(d.incident.status).toBe('acknowledged');
    expect(d.timeline.map((e: any) => e.kind)).toEqual(['acknowledged', 'comment']);
    const audit = (await adminA.get('/api/v1/audit-logs?action=incident.')).json();
    expect(audit.map((a: any) => a.action)).toContain('incident.ack');
  });
});

describe('cloud accounts', () => {
  it('encrypts credentials, never returns them, and binds ciphertext to the tenant', async () => {
    const res = await infraA.send('POST', '/api/v1/accounts', {
      provider: 'azure', name: 'Prod', auth_method: 'client_secret', tenant_id: '11111111-1111-1111-1111-111111111111',
      client_id: '22222222-2222-2222-2222-222222222222', client_secret: 'super-secret-value', subscription_ids: ['33333333-3333-3333-3333-333333333333'],
    });
    expect(res.statusCode).toBe(200);
    expect(res.body).not.toContain('super-secret-value');
    const id = res.json().id;
    const list = await viewerA.get('/api/v1/accounts');
    expect(list.body).not.toContain('super-secret-value');
    expect(list.body).not.toContain('credential_ciphertext');
    const blob = (await w.admin.query(`SELECT credential_ciphertext FROM cloud_accounts WHERE id=$1`, [id])).rows[0].credential_ciphertext;
    expect(blob.toString()).not.toContain('super-secret-value');
    const kr = parseKeyring(KEKS);
    expect(JSON.parse(open(kr, blob, `cloud_account:${w.orgA}:${id}`)).client_secret).toBe('super-secret-value');
    // Activation requires a successful validation first.
    expect((await infraA.send('POST', `/api/v1/accounts/${id}/activate`)).statusCode).toBe(400);
  });
  it('rejects malformed provider credentials', async () => {
    const r = await infraA.send('POST', '/api/v1/accounts', { provider: 'digitalocean', name: 'x', token: 'not-a-token' });
    expect(r.statusCode).toBe(400);
  });
});

describe('synthetic checks', () => {
  it('refuses private targets on public probes (SSRF)', async () => {
    const r = await infraA.send('POST', '/api/v1/synthetic-checks', { name: 'meta', kind: 'http', target: 'http://169.254.169.254/latest/meta-data' });
    expect(r.statusCode).toBe(400);
    const ok = await infraA.send('POST', '/api/v1/synthetic-checks', { name: 'site', kind: 'http', target: 'https://example.com/' });
    expect(ok.statusCode).toBe(200);
  });
});

describe('reports', () => {
  it('produces availability with methodology, and CSV/PDF exports', async () => {
    await w.admin.query(`INSERT INTO resource_state_history(org_id, resource_id, state, started_at, ended_at) VALUES
      ($1,$2,'healthy', now() - interval '10 hours', now() - interval '1 hour'), ($1,$2,'down', now() - interval '1 hour', NULL)`, [w.orgA, resA]);
    const j = (await viewerA.get('/api/v1/reports/availability?range=24h')).json();
    expect(j.data.methodology).toMatch(/Maintenance/);
    const r = j.data.resources.find((x: any) => x.id === resA);
    expect(r.percent).toBeCloseTo(90, 0);
    const csv = await viewerA.get('/api/v1/reports/inventory?format=csv');
    expect(csv.headers['content-type']).toMatch(/text\/csv/);
    expect(csv.body).toContain('alpha-web-01');
    expect(csv.body).not.toContain('bravo-secret-db');
    const pdf = await viewerA.get('/api/v1/reports/incidents?format=pdf');
    expect(pdf.headers['content-type']).toBe('application/pdf');
    expect(pdf.rawPayload.subarray(0, 4).toString()).toBe('%PDF');
  });
});

describe('dashboard', () => {
  it('summarises only the active tenant', async () => {
    const d = (await adminA.get('/api/v1/dashboard/summary')).json();
    expect(d.counts).toEqual([{ state: 'critical', n: 1 }]);
    expect(d.disks[0].value).toBe(95);
    expect(JSON.stringify(d)).not.toContain('bravo');
  });
});

void pg;
