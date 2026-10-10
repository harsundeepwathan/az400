// Organization administration, audit log and monitoring-platform health.
import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { ROLES } from '../auth/rbac.js';
import { requirePerm } from '../auth/session.js';
import { withScope, type Tx } from '../db.js';
import { audit } from '../lib/audit.js';
import { badRequest, notFound } from '../lib/errors.js';
import { body, params, query } from '../lib/http.js';

async function adminCount(tx: Tx) {
  return (await tx.query(`SELECT count(*)::int AS n FROM memberships WHERE org_id = app_org_id() AND role='org_admin'`)).rows[0].n as number;
}

const routes: FastifyPluginAsync = async (app) => {
  const { db } = app.deps;

  app.get('/members', async (req) => {
    const s = requirePerm(req, 'read');
    return withScope(db, s, async (tx) => (await tx.query(`SELECT u.id, u.email, u.display_name, m.role, u.last_login_at, u.disabled,
        (u.oidc_subject IS NOT NULL) AS sso_linked FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.org_id = app_org_id() ORDER BY u.display_name`)).rows);
  });

  app.post('/members', async (req) => {
    const s = requirePerm(req, 'users.manage');
    const b = body(req, z.object({ email: z.string().email().max(254), display_name: z.string().trim().min(1).max(200), role: z.enum(ROLES as [string, ...string[]]) }));
    return withScope(db, s, async (tx) => {
      const uid = (await tx.query(`SELECT skywatch_invite_user($1,$2) AS id`, [b.email, b.display_name])).rows[0].id;
      await tx.query(`INSERT INTO memberships(org_id, user_id, role) VALUES ($1,$2,$3) ON CONFLICT (org_id, user_id) DO UPDATE SET role=EXCLUDED.role`,
        [s.orgId, uid, b.role]);
      await audit(tx, { ...s, action: 'member.invited', targetType: 'user', targetId: uid, details: { email: b.email, role: b.role }, ip: req.ip });
      return { id: uid, email: b.email, role: b.role };
    });
  });

  app.patch('/members/:userId', async (req) => {
    const s = requirePerm(req, 'users.manage');
    const { userId } = params(req, z.object({ userId: z.string().uuid() }));
    const b = body(req, z.object({ role: z.enum(ROLES as [string, ...string[]]) }));
    return withScope(db, s, async (tx) => {
      const cur = (await tx.query(`SELECT role FROM memberships WHERE org_id=app_org_id() AND user_id=$1 FOR UPDATE`, [userId])).rows[0];
      if (!cur) throw notFound('Member not found');
      if (cur.role === 'org_admin' && b.role !== 'org_admin' && (await adminCount(tx)) <= 1) throw badRequest('An organization needs at least one administrator');
      await tx.query(`UPDATE memberships SET role=$2 WHERE org_id=app_org_id() AND user_id=$1`, [userId, b.role]);
      await audit(tx, { ...s, action: 'member.role_changed', targetType: 'user', targetId: userId, details: { from: cur.role, to: b.role }, ip: req.ip });
      return { ok: true };
    });
  });

  app.delete('/members/:userId', async (req) => {
    const s = requirePerm(req, 'users.manage');
    const { userId } = params(req, z.object({ userId: z.string().uuid() }));
    return withScope(db, s, async (tx) => {
      const cur = (await tx.query(`SELECT role FROM memberships WHERE org_id=app_org_id() AND user_id=$1 FOR UPDATE`, [userId])).rows[0];
      if (!cur) throw notFound('Member not found');
      if (cur.role === 'org_admin' && (await adminCount(tx)) <= 1) throw badRequest('An organization needs at least one administrator');
      await tx.query(`DELETE FROM memberships WHERE org_id=app_org_id() AND user_id=$1`, [userId]);
      await audit(tx, { ...s, action: 'member.removed', targetType: 'user', targetId: userId, ip: req.ip });
      return { ok: true };
    });
  });

  app.get('/audit-logs', async (req) => {
    const s = requirePerm(req, 'audit.read');
    const q = query(req, z.object({ limit: z.coerce.number().int().min(1).max(1000).default(200), action: z.string().max(100).optional() }));
    return withScope(db, s, async (tx) => (await tx.query(`SELECT id, at, actor_type, actor_label, action, target_type, target_id, details, ip
      FROM audit_logs WHERE ($2::text IS NULL OR action LIKE $2 || '%') ORDER BY at DESC LIMIT $1`, [q.limit, q.action ?? null])).rows);
  });

  // The monitoring platform's own health, scoped to what this organization depends on.
  app.get('/platform/health', async (req) => {
    const s = requirePerm(req, 'read');
    return withScope(db, s, async (tx) => {
      const [jobs, runs, agentVersions, deliveries, ingest] = await Promise.all([
        tx.query(`SELECT j.kind, j.last_status, j.last_error, j.last_finished_at, j.next_run_at, j.consecutive_failures, j.last_duration_ms,
            a.id AS account_id, a.name AS account_name, a.provider, a.status AS account_status, a.throttle_events, a.last_throttled_at,
            (j.next_run_at < now() - interval '5 minutes' AND j.lease_owner IS NULL) AS overdue
          FROM collection_jobs j JOIN cloud_accounts a ON a.id = j.cloud_account_id ORDER BY a.name, j.kind`),
        tx.query(`SELECT date_trunc('hour', started_at) AS t, count(*)::int AS runs,
            count(*) FILTER (WHERE status IN ('error'))::int AS errors, count(*) FILTER (WHERE status='throttled')::int AS throttled,
            sum(api_calls)::int AS api_calls, sum(throttled_calls)::int AS throttled_calls
          FROM collector_runs WHERE started_at > now() - interval '24 hours' GROUP BY 1 ORDER BY 1`),
        tx.query(`SELECT agent_version, count(*)::int AS n, count(*) FILTER (WHERE last_heartbeat_at > now() - interval '5 minutes')::int AS reporting
          FROM agents WHERE status='active' GROUP BY 1 ORDER BY 1`),
        tx.query(`SELECT status, count(*)::int AS n FROM notification_deliveries WHERE created_at > now() - interval '24 hours' GROUP BY 1`),
        tx.query(`SELECT max(received_at) AS last_received, count(*)::int AS last_5m FROM heartbeats WHERE received_at > now() - interval '5 minutes'`),
      ]);
      // Platform instances are global infrastructure; expose only liveness, not stats of other tenants.
      const instances = (await db.query(`SELECT instance_id, roles, version, last_heartbeat, (last_heartbeat > now() - interval '60 seconds') AS alive
        FROM platform_instances ORDER BY instance_id`).catch(() => ({ rows: [] }))).rows;
      return { jobs: jobs.rows, runs: runs.rows, agent_versions: agentVersions.rows, deliveries: deliveries.rows,
        ingest: ingest.rows[0], instances };
    });
  });
};

export default routes;
