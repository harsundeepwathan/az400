import type { FastifyPluginAsync } from 'fastify';
import { requirePerm } from '../auth/session.js';
import { withScope } from '../db.js';

const routes: FastifyPluginAsync = async (app) => {
  const { db } = app.deps;

  // Everything on the global dashboard comes from normalized telemetry and computed
  // state; nothing is synthesized here.
  app.get('/dashboard/summary', async (req) => {
    const s = requirePerm(req, 'read');
    return withScope(db, s, async (tx) => {
      const counts = (await tx.query(`SELECT operational_state AS state, count(*)::int AS n FROM resources
        WHERE deleted_at IS NULL AND monitoring_enabled GROUP BY 1`)).rows;
      const byProvider = (await tx.query(`SELECT provider, operational_state AS state, count(*)::int AS n FROM resources
        WHERE deleted_at IS NULL AND monitoring_enabled GROUP BY 1,2 ORDER BY 1`)).rows;
      const incidents = (await tx.query(`SELECT
          count(*) FILTER (WHERE status='open')::int AS unacknowledged,
          count(*) FILTER (WHERE status='acknowledged')::int AS acknowledged,
          count(*) FILTER (WHERE status<>'resolved' AND severity='critical')::int AS critical_open
        FROM incidents WHERE status <> 'resolved' AND parent_incident_id IS NULL`)).rows[0];
      const critical = (await tx.query(`SELECT i.id, i.number, i.title, i.severity, i.status, i.first_detected_at, i.last_observed_at,
          r.name AS resource_name, r.provider, r.region
        FROM incidents i LEFT JOIN resources r ON r.id = i.resource_id
        WHERE i.status <> 'resolved' AND i.parent_incident_id IS NULL
        ORDER BY (i.severity='critical') DESC, (i.status='open') DESC, i.first_detected_at DESC LIMIT 8`)).rows;
      const recent = (await tx.query(`SELECT i.id, i.number, i.title, i.severity, i.status, i.first_detected_at, i.resolved_at,
          r.name AS resource_name
        FROM incidents i LEFT JOIN resources r ON r.id = i.resource_id
        WHERE i.parent_incident_id IS NULL ORDER BY i.first_detected_at DESC LIMIT 10`)).rows;
      const disks = (await tx.query(`SELECT r.id, r.name, r.provider, m.series, m.value, m.ts,
          (SELECT value FROM metric_latest t WHERE t.resource_id=m.resource_id AND t.metric='disk.total_bytes' AND t.series=m.series) AS total_bytes
        FROM metric_latest m JOIN resources r ON r.id = m.resource_id
        WHERE m.metric='disk.utilization' AND r.deleted_at IS NULL AND m.ts > now() - interval '30 minutes'
        ORDER BY m.value DESC LIMIT 8`)).rows;
      const topCpu = (await tx.query(`SELECT r.id, r.name, r.provider, m.value, m.ts FROM metric_latest m JOIN resources r ON r.id=m.resource_id
        WHERE m.metric='cpu.utilization' AND m.series='' AND r.deleted_at IS NULL AND m.ts > now() - interval '30 minutes'
        ORDER BY m.value DESC LIMIT 6`)).rows;
      const topMem = (await tx.query(`SELECT r.id, r.name, r.provider, m.value, m.ts FROM metric_latest m JOIN resources r ON r.id=m.resource_id
        WHERE m.metric='memory.utilization' AND m.series='' AND r.deleted_at IS NULL AND m.ts > now() - interval '30 minutes'
        ORDER BY m.value DESC LIMIT 6`)).rows;
      const services = (await tx.query(`SELECT
          count(*) FILTER (WHERE expected_state <> 'any')::int AS monitored,
          count(*) FILTER (WHERE expected_state <> 'any' AND current_state = expected_state)::int AS ok,
          count(*) FILTER (WHERE expected_state <> 'any' AND current_state IS DISTINCT FROM expected_state)::int AS failing
        FROM service_checks`)).rows[0];
      const failingServices = (await tx.query(`SELECT s.id, s.name, s.display_name, s.current_state, s.expected_state, s.last_change_at,
          r.id AS resource_id, r.name AS resource_name
        FROM service_checks s JOIN resources r ON r.id = s.resource_id
        WHERE s.expected_state <> 'any' AND s.current_state IS DISTINCT FROM s.expected_state ORDER BY s.last_change_at DESC NULLS LAST LIMIT 8`)).rows;
      // Fleet trend: average of per-resource 5-minute means over the last 6 hours.
      const trend = (await tx.query(`SELECT metric, date_bin('5 minutes', ts, timestamptz 'epoch') AS t, avg(value)::float AS avg,
          max(value)::float AS max, count(DISTINCT resource_id)::int AS resources
        FROM metric_samples WHERE metric IN ('cpu.utilization','memory.utilization') AND series='' AND ts > now() - interval '6 hours'
        GROUP BY 1,2 ORDER BY 2`)).rows;
      // Availability timeline: resources per state per hour over 24h, from state history.
      const timeline = (await tx.query(`WITH hours AS (
          SELECT generate_series(date_trunc('hour', now()) - interval '23 hours', date_trunc('hour', now()), interval '1 hour') AS h)
        SELECT h.h AS t, sh.state, count(DISTINCT sh.resource_id)::int AS n
        FROM hours h JOIN resource_state_history sh ON sh.started_at < h.h + interval '1 hour' AND coalesce(sh.ended_at, now()) > h.h
        JOIN resources r ON r.id = sh.resource_id AND r.deleted_at IS NULL
        GROUP BY 1,2 ORDER BY 1`)).rows;
      const accounts = (await tx.query(`SELECT id, name, provider, status, status_reason, last_success_at, auth_method FROM cloud_accounts ORDER BY provider, name`)).rows;
      return { counts, by_provider: byProvider, incidents, critical, recent, disks, top_cpu: topCpu, top_memory: topMem,
        services, failing_services: failingServices, trend, timeline, accounts };
    });
  });
};

export default routes;
