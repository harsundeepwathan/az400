import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { requirePerm } from '../auth/session.js';
import { withScope, type Tx } from '../db.js';
import { audit } from '../lib/audit.js';
import { badRequest, notFound } from '../lib/errors.js';
import { body, idParams, params, query } from '../lib/http.js';

// Serialize with the evaluator, which holds the same per-org transaction lock while it
// updates incidents.
const lockOrg = (tx: Tx, orgId: string) => tx.query(`SELECT pg_advisory_xact_lock(hashtext($1))`, ['eval:' + orgId]);

const routes: FastifyPluginAsync = async (app) => {
  const { db } = app.deps;

  app.get('/incidents', async (req) => {
    const s = requirePerm(req, 'read');
    const q = query(req, z.object({
      status: z.enum(['active', 'open', 'acknowledged', 'resolved', 'all']).default('active'),
      severity: z.enum(['warning', 'critical']).optional(),
      q: z.string().max(200).optional(),
      resource: z.string().uuid().optional(),
      limit: z.coerce.number().int().min(1).max(500).default(200),
    }));
    const where = ['true'];
    const args: unknown[] = [];
    if (q.status === 'active') where.push(`i.status <> 'resolved'`);
    else if (q.status !== 'all') { args.push(q.status); where.push(`i.status = $${args.length}`); }
    if (q.severity) { args.push(q.severity); where.push(`i.severity = $${args.length}`); }
    if (q.resource) { args.push(q.resource); where.push(`i.resource_id = $${args.length}`); }
    if (q.q) { args.push(`%${q.q}%`); where.push(`(i.title ILIKE $${args.length} OR i.trigger_summary ILIKE $${args.length})`); }
    args.push(q.limit);
    return withScope(db, s, async (tx) => (await tx.query(
      `SELECT i.id, i.number, i.title, i.severity, i.status, i.trigger_summary, i.first_detected_at, i.last_observed_at,
         i.acknowledged_at, i.resolved_at, i.resolution, i.parent_incident_id, i.correlation_note,
         r.id AS resource_id, r.name AS resource_name, r.provider, r.region, r.resource_type,
         a.name AS account_name, u.display_name AS assignee,
         (SELECT count(*)::int FROM incidents c WHERE c.parent_incident_id = i.id) AS child_count,
         (SELECT count(*)::int FROM alert_instances ai WHERE ai.incident_id = i.id AND ai.state='firing') AS firing_alerts
       FROM incidents i LEFT JOIN resources r ON r.id = i.resource_id LEFT JOIN cloud_accounts a ON a.id = i.cloud_account_id
       LEFT JOIN users u ON u.id = i.assigned_to
       WHERE ${where.join(' AND ')}
       ORDER BY (i.status='resolved'), (i.severity='critical') DESC, i.first_detected_at DESC LIMIT $${args.length}`, args)).rows);
  });

  app.get('/incidents/:id', async (req) => {
    const s = requirePerm(req, 'read');
    const { id } = params(req, idParams);
    return withScope(db, s, async (tx) => {
      const inc = (await tx.query(`SELECT i.*, r.name AS resource_name, r.provider, r.region, r.resource_type, r.operational_state AS resource_state,
          r.state_reason AS resource_state_reason, a.name AS account_name, ack.display_name AS acknowledged_by_name, asg.display_name AS assignee_name,
          p.title AS parent_title
        FROM incidents i LEFT JOIN resources r ON r.id=i.resource_id LEFT JOIN cloud_accounts a ON a.id=i.cloud_account_id
        LEFT JOIN users ack ON ack.id=i.acknowledged_by LEFT JOIN users asg ON asg.id=i.assigned_to
        LEFT JOIN incidents p ON p.id = i.parent_incident_id
        WHERE i.id=$1`, [id])).rows[0];
      if (!inc) throw notFound('Incident not found');
      const [alerts, timeline, children, deliveries, changes] = await Promise.all([
        tx.query(`SELECT ai.id, ai.state, ai.value, ai.summary, ai.series, ai.firing_since, ai.resolved_at, ai.pending_since,
            ar.name AS rule_name, ar.kind, ar.metric, ar.severity, ar.operator, ar.threshold
          FROM alert_instances ai JOIN alert_rules ar ON ar.id = ai.rule_id WHERE ai.incident_id=$1 ORDER BY ai.firing_since`, [id]),
        tx.query(`SELECT e.id, e.at, e.kind, e.message, e.data, u.display_name AS actor FROM incident_events e
          LEFT JOIN users u ON u.id = e.actor_user_id WHERE e.incident_id=$1 ORDER BY e.at, e.id`, [id]),
        tx.query(`SELECT c.id, c.number, c.title, c.severity, c.status, r.name AS resource_name FROM incidents c
          LEFT JOIN resources r ON r.id = c.resource_id WHERE c.parent_incident_id=$1 ORDER BY c.first_detected_at`, [id]),
        tx.query(`SELECT d.event, d.status, d.attempts, d.last_error, d.created_at, d.sent_at, c.name AS channel, c.kind
          FROM notification_deliveries d JOIN notification_channels c ON c.id=d.channel_id WHERE d.incident_id=$1 ORDER BY d.created_at`, [id]),
        // "What changed before the failure": infrastructure events on the resource in the
        // two hours before detection. Shown as context, not as an asserted cause.
        inc.resource_id
          ? tx.query(`SELECT source, kind, severity, message, at FROM infra_events WHERE resource_id=$1
              AND at BETWEEN $2::timestamptz - interval '2 hours' AND $3 ORDER BY at DESC LIMIT 30`, [inc.resource_id, inc.first_detected_at, inc.last_observed_at])
          : Promise.resolve({ rows: [] }),
      ]);
      return { incident: inc, alerts: alerts.rows, timeline: timeline.rows, children: children.rows,
        notifications: deliveries.rows, recent_changes: changes.rows };
    });
  });

  async function transition(req: any, action: 'ack' | 'resolve' | 'assign' | 'comment') {
    const s = requirePerm(req, 'incident.manage');
    const { id } = params(req, idParams);
    const b = body(req, z.object({ note: z.string().max(4000).optional(), user_id: z.string().uuid().nullable().optional() }));
    return withScope(db, s, async (tx) => {
      await lockOrg(tx, s.orgId);
      const inc = (await tx.query(`SELECT id, status FROM incidents WHERE id=$1 FOR UPDATE`, [id])).rows[0];
      if (!inc) throw notFound('Incident not found');
      let msg = '';
      switch (action) {
        case 'ack':
          if (inc.status !== 'open') throw badRequest(`Incident is ${inc.status}`);
          await tx.query(`UPDATE incidents SET status='acknowledged', acknowledged_at=now(), acknowledged_by=$2,
            assigned_to=coalesce(assigned_to, $2), next_escalation_at=NULL WHERE id=$1`, [id, s.userId]);
          msg = 'Acknowledged' + (b.note ? `: ${b.note}` : '');
          break;
        case 'resolve':
          if (inc.status === 'resolved') throw badRequest('Incident is already resolved');
          await tx.query(`UPDATE incidents SET status='resolved', resolved_at=now(), resolution='manual' WHERE id=$1`, [id]);
          msg = 'Resolved manually' + (b.note ? `: ${b.note}` : '') +
            '. Alerts still firing will not reopen this incident; they must clear and fire again.';
          break;
        case 'assign': {
          if (b.user_id) {
            const m = (await tx.query(`SELECT 1 FROM memberships WHERE user_id=$1`, [b.user_id])).rows[0];
            if (!m) throw badRequest('Assignee must be a member of this organization');
          }
          await tx.query(`UPDATE incidents SET assigned_to=$2 WHERE id=$1`, [id, b.user_id ?? null]);
          const name = b.user_id ? (await tx.query(`SELECT display_name FROM users WHERE id=$1`, [b.user_id])).rows[0]?.display_name : null;
          msg = name ? `Assigned to ${name}` : 'Unassigned';
          break;
        }
        case 'comment':
          if (!b.note?.trim()) throw badRequest('Comment is empty');
          msg = b.note.trim();
          break;
      }
      await tx.query(`INSERT INTO incident_events(org_id, incident_id, kind, actor_user_id, message) VALUES ($1,$2,$3,$4,$5)`,
        [s.orgId, id, { ack: 'acknowledged', resolve: 'resolved_manual', assign: 'assigned', comment: 'comment' }[action], s.userId, msg]);
      await audit(tx, { ...s, action: `incident.${action}`, targetType: 'incident', targetId: id, details: b, ip: req.ip });
      return { ok: true };
    });
  }

  app.post('/incidents/:id/ack', (req) => transition(req, 'ack'));
  app.post('/incidents/:id/resolve', (req) => transition(req, 'resolve'));
  app.post('/incidents/:id/assign', (req) => transition(req, 'assign'));
  app.post('/incidents/:id/comment', (req) => transition(req, 'comment'));
};

export default routes;
