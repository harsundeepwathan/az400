import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { requirePerm } from '../auth/session.js';
import { withScope } from '../db.js';
import { audit } from '../lib/audit.js';
import { computeAvailability, METHODOLOGY } from '../lib/availability.js';
import { notFound } from '../lib/errors.js';
import { body, idParams, params, query, rangeSchema, resolveRange, uuid } from '../lib/http.js';

const listQuery = z.object({
  q: z.string().max(200).optional(),
  provider: z.string().max(40).optional(),
  type: z.string().max(60).optional(),
  region: z.string().max(80).optional(),
  state: z.string().max(200).optional(), // comma separated
  account: uuid.optional(),
  environment: z.string().max(80).optional(),
  tag: z.string().max(300).optional(), // key or key:value
  monitored: z.enum(['true', 'false', 'all']).default('true'),
  sort: z.enum(['severity', 'name', 'cpu', 'memory', 'disk', 'heartbeat']).default('severity'),
  limit: z.coerce.number().int().min(1).max(2000).default(500),
});

const metricsQuery = rangeSchema.extend({
  metrics: z.string().regex(/^[a-z0-9_.,]+$/).max(500),
});

const SEVERITY_ORDER = `CASE r.operational_state WHEN 'down' THEN 0 WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 WHEN 'unknown' THEN 3
  WHEN 'no_data' THEN 4 WHEN 'maintenance' THEN 5 WHEN 'healthy' THEN 6 ELSE 7 END`;

const routes: FastifyPluginAsync = async (app) => {
  const { db } = app.deps;

  app.get('/resources', async (req) => {
    const s = requirePerm(req, 'read');
    const q = query(req, listQuery);
    const where: string[] = ['r.deleted_at IS NULL'];
    const args: unknown[] = [];
    const add = (sql: string, v: unknown) => {
      args.push(v);
      where.push(sql.replace('?', `$${args.length}`));
    };
    if (q.q) {
      args.push(`%${q.q.replace(/[%_\\]/g, '\\$&')}%`);
      where.push(`(r.name ILIKE $${args.length} OR r.provider_resource_id ILIKE $${args.length})`);
    }
    if (q.provider) add('r.provider = ?', q.provider);
    if (q.type) add('r.resource_type = ?', q.type);
    if (q.region) add('r.region = ?', q.region);
    if (q.account) add('r.cloud_account_id = ?', q.account);
    if (q.environment) add('r.environment = ?', q.environment);
    if (q.state) add('r.operational_state = ANY(?)', q.state.split(','));
    if (q.monitored !== 'all') add('r.monitoring_enabled = ?', q.monitored === 'true');
    if (q.tag) {
      const [k, v] = q.tag.split(/:(.*)/s);
      if (v === undefined) add('EXISTS (SELECT 1 FROM resource_tags t WHERE t.resource_id=r.id AND t.key = ?)', k);
      else {
        args.push(k, v);
        where.push(`EXISTS (SELECT 1 FROM resource_tags t WHERE t.resource_id=r.id AND t.key = $${args.length - 1} AND t.value = $${args.length})`);
      }
    }
    const order = {
      severity: `${SEVERITY_ORDER}, r.name`,
      name: 'r.name',
      cpu: 'cpu DESC NULLS LAST',
      memory: 'mem DESC NULLS LAST',
      disk: 'disk_max DESC NULLS LAST',
      heartbeat: 'last_heartbeat ASC NULLS FIRST',
    }[q.sort];
    args.push(q.limit);
    return withScope(db, s, async (tx) => {
      const { rows } = await tx.query(
        `SELECT r.id, r.name, r.provider, r.resource_type, r.native_type, r.region, r.environment, r.os_type, r.os_name,
           r.power_state, r.provider_state_raw, r.provider_health, r.operational_state, r.state_reason, r.state_since,
           r.monitoring_enabled, r.flapping, r.cloud_account_id, a.name AS account_name, r.last_telemetry_at,
           (SELECT value FROM metric_latest m WHERE m.resource_id=r.id AND m.metric='cpu.utilization' AND m.series='' ORDER BY (m.source='agent') DESC LIMIT 1) AS cpu,
           (SELECT value FROM metric_latest m WHERE m.resource_id=r.id AND m.metric='memory.utilization' AND m.series='' ORDER BY (m.source='agent') DESC LIMIT 1) AS mem,
           (SELECT max(value) FROM metric_latest m WHERE m.resource_id=r.id AND m.metric='disk.utilization') AS disk_max,
           GREATEST((SELECT max(last_heartbeat_at) FROM agents g WHERE g.resource_id=r.id AND g.status='active'), r.guest_heartbeat_at) AS last_heartbeat,
           EXISTS (SELECT 1 FROM agents g WHERE g.resource_id=r.id AND g.status='active') AS has_agent,
           r.metric_gaps,
           coalesce((SELECT jsonb_object_agg(key, value) FROM resource_tags t WHERE t.resource_id=r.id), '{}') AS tags
         FROM resources r LEFT JOIN cloud_accounts a ON a.id = r.cloud_account_id
         WHERE ${where.join(' AND ')}
         ORDER BY ${order}
         LIMIT $${args.length}`,
        args,
      );
      const facets = (await tx.query(`SELECT
          array_agg(DISTINCT provider) AS providers, array_agg(DISTINCT resource_type) AS types,
          array_agg(DISTINCT region) FILTER (WHERE region IS NOT NULL) AS regions,
          array_agg(DISTINCT environment) FILTER (WHERE environment IS NOT NULL) AS environments
        FROM resources WHERE deleted_at IS NULL`)).rows[0];
      return { items: rows, facets };
    });
  });

  app.get('/resources/:id', async (req) => {
    const s = requirePerm(req, 'read');
    const { id } = params(req, idParams);
    return withScope(db, s, async (tx) => {
      const r = (await tx.query(`SELECT r.*, a.name AS account_name, a.status AS account_status, a.status_reason AS account_status_reason
        FROM resources r LEFT JOIN cloud_accounts a ON a.id=r.cloud_account_id WHERE r.id=$1`, [id])).rows[0];
      if (!r) throw notFound('Resource not found');
      const [tags, agent, services, incidents, events, relations, latest, checks] = await Promise.all([
        tx.query(`SELECT key, value FROM resource_tags WHERE resource_id=$1 ORDER BY key`, [id]),
        tx.query(`SELECT id, hostname, os_type, os_name, os_version, kernel_version, arch, agent_version, enrolled_at, last_heartbeat_at,
            last_heartbeat_latency_ms, last_boot_at, last_queue_depth, last_dropped_batches, collector_errors, status, secret_rotated_at
          FROM agents WHERE resource_id=$1 ORDER BY (status='active') DESC, enrolled_at DESC LIMIT 1`, [id]),
        tx.query(`SELECT id, platform, name, display_name, expected_state, critical, startup_type, current_state, sub_state, pid,
            restart_count, last_change_at, last_reported_at, discovered
          FROM service_checks WHERE resource_id=$1 ORDER BY (expected_state <> 'any') DESC, (current_state IS DISTINCT FROM expected_state AND expected_state <> 'any') DESC, name`, [id]),
        tx.query(`SELECT id, number, title, severity, status, first_detected_at, last_observed_at, resolved_at FROM incidents
          WHERE resource_id=$1 ORDER BY (status <> 'resolved') DESC, first_detected_at DESC LIMIT 20`, [id]),
        tx.query(`SELECT id, source, kind, severity, message, at FROM infra_events WHERE resource_id=$1 ORDER BY at DESC LIMIT 50`, [id]),
        tx.query(`SELECT rel.kind, 'outgoing' AS direction, o.id, o.name, o.resource_type, o.operational_state FROM resource_relations rel
            JOIN resources o ON o.id = rel.to_resource_id WHERE rel.from_resource_id=$1
          UNION ALL
          SELECT rel.kind, 'incoming', o.id, o.name, o.resource_type, o.operational_state FROM resource_relations rel
            JOIN resources o ON o.id = rel.from_resource_id WHERE rel.to_resource_id=$1`, [id]),
        tx.query(`SELECT metric, series, value, ts, source FROM metric_latest WHERE resource_id=$1 ORDER BY metric, series`, [id]),
        tx.query(`SELECT id, name, kind, target, last_ok, last_run_at, last_latency_ms, last_error, counts_for_liveness FROM synthetic_checks WHERE resource_id=$1`, [id]),
      ]);
      return { resource: r, tags: tags.rows, agent: agent.rows[0] ?? null, services: services.rows, incidents: incidents.rows,
        events: events.rows, relations: relations.rows, latest: latest.rows, checks: checks.rows };
    });
  });

  /**
   * Time series for a resource. Resolution adapts to the range: raw 1-minute data up to
   * 6 hours, 5-minute buckets up to 48 hours (raw retention is 30 days), and hourly
   * rollups beyond. When several sources report a metric, the agent's is preferred.
   */
  app.get('/resources/:id/metrics', async (req) => {
    const s = requirePerm(req, 'read');
    const { id } = params(req, idParams);
    const q = query(req, metricsQuery);
    const { from, to } = resolveRange(q);
    const metrics = q.metrics.split(',').filter(Boolean).slice(0, 12);
    const span = to.getTime() - from.getTime();
    return withScope(db, s, async (tx) => {
      let rows;
      let bucket: string;
      if (span <= 48 * 3600e3) {
        bucket = span <= 6 * 3600e3 ? '1 minute' : '5 minutes';
        rows = (await tx.query(`WITH src AS (
            SELECT DISTINCT ON (metric) metric, source FROM metric_samples
            WHERE resource_id=$1 AND metric = ANY($2) AND ts BETWEEN $3 AND $4
            ORDER BY metric, (source='agent') DESC, ts DESC)
          SELECT m.metric, m.series, date_bin($5::interval, m.ts, timestamptz 'epoch') AS t,
            avg(m.value)::float AS avg, min(m.value)::float AS min, max(m.value)::float AS max
          FROM metric_samples m JOIN src USING (metric, source)
          WHERE m.resource_id=$1 AND m.ts BETWEEN $3 AND $4
          GROUP BY 1,2,3 ORDER BY 3`, [id, metrics, from, to, bucket])).rows;
      } else {
        bucket = '1 hour';
        rows = (await tx.query(`WITH src AS (
            SELECT DISTINCT ON (metric) metric, source FROM metric_rollups_1h
            WHERE resource_id=$1 AND metric = ANY($2) AND bucket BETWEEN $3 AND $4
            ORDER BY metric, (source='agent') DESC, bucket DESC)
          SELECT r.metric, r.series, r.bucket AS t, r.avg::float, r.min::float, r.max::float
          FROM metric_rollups_1h r JOIN src USING (metric, source)
          WHERE r.resource_id=$1 AND r.bucket BETWEEN $3 AND $4 ORDER BY 3`, [id, metrics, from, to])).rows;
      }
      const series: Record<string, { metric: string; series: string; points: [string, number, number, number][] }> = {};
      for (const r of rows) {
        const key = `${r.metric}|${r.series}`;
        (series[key] ??= { metric: r.metric, series: r.series, points: [] }).points.push([r.t, r.avg, r.min, r.max]);
      }
      const sources = (await tx.query(`SELECT DISTINCT metric, source FROM metric_latest WHERE resource_id=$1 AND metric = ANY($2)`, [id, metrics])).rows;
      return { from, to, bucket, series: Object.values(series), sources };
    });
  });

  app.get('/resources/:id/heartbeats', async (req) => {
    const s = requirePerm(req, 'read');
    const { id } = params(req, idParams);
    const { from, to } = resolveRange(query(req, rangeSchema));
    const bucket = to.getTime() - from.getTime() <= 6 * 3600e3 ? '1 minute' : to.getTime() - from.getTime() <= 48 * 3600e3 ? '10 minutes' : '1 hour';
    return withScope(db, s, async (tx) => ({
      bucket,
      points: (await tx.query(`SELECT date_bin($4::interval, received_at, timestamptz 'epoch') AS t, count(*)::int AS n,
          avg(latency_ms)::int AS latency_ms, max(received_at) AS last
        FROM heartbeats WHERE resource_id=$1 AND received_at BETWEEN $2 AND $3 GROUP BY 1 ORDER BY 1`, [id, from, to, bucket])).rows,
    }));
  });

  app.get('/resources/:id/availability', async (req) => {
    const s = requirePerm(req, 'read');
    const { id } = params(req, idParams);
    const { from, to } = resolveRange(query(req, rangeSchema));
    return withScope(db, s, async (tx) => {
      const { rows } = await tx.query(`SELECT state, reason, started_at, ended_at FROM resource_state_history
        WHERE resource_id=$1 AND started_at < $3 AND coalesce(ended_at, now()) > $2 ORDER BY started_at`, [id, from, to]);
      const av = computeAvailability(rows.map((r) => ({ state: r.state, start: r.started_at, end: r.ended_at })), from, to);
      return { from, to, availability: av, intervals: rows, methodology: METHODOLOGY };
    });
  });

  app.patch('/resources/:id', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const { id } = params(req, idParams);
    const b = body(req, z.object({ monitoring_enabled: z.boolean().optional(), environment: z.string().max(80).nullable().optional() }));
    return withScope(db, s, async (tx) => {
      const { rows } = await tx.query(`UPDATE resources SET monitoring_enabled = coalesce($2, monitoring_enabled),
          environment = CASE WHEN $4 THEN $3 ELSE environment END WHERE id=$1 RETURNING id, monitoring_enabled, environment`,
        [id, b.monitoring_enabled ?? null, b.environment ?? null, b.environment !== undefined]);
      if (!rows[0]) throw notFound();
      await audit(tx, { ...s, action: 'resource.updated', targetType: 'resource', targetId: id, details: b, ip: req.ip });
      return rows[0];
    });
  });

  // Operators designate which services must be running. Discovered services default to
  // "any" (informational) so a legitimately stopped manual-start service never alerts.
  app.put('/resources/:id/services/:serviceId', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const p = params(req, z.object({ id: uuid, serviceId: uuid }));
    const b = body(req, z.object({ expected_state: z.enum(['running', 'stopped', 'any']), critical: z.boolean().default(false) }));
    return withScope(db, s, async (tx) => {
      const { rows } = await tx.query(`UPDATE service_checks SET expected_state=$3, critical=$4 WHERE id=$2 AND resource_id=$1
        RETURNING id, name, expected_state, critical`, [p.id, p.serviceId, b.expected_state, b.critical]);
      if (!rows[0]) throw notFound('Service not found');
      await audit(tx, { ...s, action: 'service_check.updated', targetType: 'service_check', targetId: p.serviceId, details: b, ip: req.ip });
      return rows[0];
    });
  });

  app.post('/resources/:id/services', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const { id } = params(req, idParams);
    const b = body(req, z.object({
      platform: z.enum(['windows', 'systemd']),
      name: z.string().regex(/^[A-Za-z0-9@._:\-]{1,200}$/, 'Invalid service name'),
      expected_state: z.enum(['running', 'stopped']).default('running'),
      critical: z.boolean().default(true),
    }));
    return withScope(db, s, async (tx) => {
      const r = (await tx.query(`SELECT id FROM resources WHERE id=$1`, [id])).rows[0];
      if (!r) throw notFound();
      const { rows } = await tx.query(`INSERT INTO service_checks(org_id, resource_id, platform, name, expected_state, critical)
        VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (resource_id, platform, name) DO UPDATE SET expected_state=EXCLUDED.expected_state,
        critical=EXCLUDED.critical RETURNING id, name, expected_state, critical`, [s.orgId, id, b.platform, b.name, b.expected_state, b.critical]);
      await audit(tx, { ...s, action: 'service_check.created', targetType: 'service_check', targetId: rows[0].id, details: b, ip: req.ip });
      return rows[0];
    });
  });

  app.get('/events', async (req) => {
    const s = requirePerm(req, 'read');
    const q = query(req, rangeSchema.extend({ limit: z.coerce.number().int().min(1).max(500).default(200) }));
    const { from, to } = resolveRange({ ...q, range: q.range ?? '24h' });
    return withScope(db, s, async (tx) => (await tx.query(`SELECT e.id, e.source, e.kind, e.severity, e.message, e.at, r.id AS resource_id, r.name AS resource_name
      FROM infra_events e LEFT JOIN resources r ON r.id = e.resource_id WHERE e.at BETWEEN $1 AND $2 ORDER BY e.at DESC LIMIT $3`, [from, to, q.limit])).rows);
  });
};

export default routes;
