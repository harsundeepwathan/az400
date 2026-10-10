// Monitoring configuration: alert rules, monitoring policy, maintenance windows,
// notification channels, escalation policies and synthetic checks.
import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { requirePerm } from '../auth/session.js';
import { withScope } from '../db.js';
import { audit } from '../lib/audit.js';
import { channelAad, seal } from '../lib/envelope.js';
import { badRequest, notFound } from '../lib/errors.js';
import { body, idParams, params, query } from '../lib/http.js';
import { validateTarget, validateWebhookUrl } from '../lib/targets.js';

const strList = z.array(z.string().max(200)).max(200);
const scopeSchema = z.object({
  providers: strList.optional(), resource_types: strList.optional(), environments: strList.optional(), os_types: strList.optional(),
  regions: strList.optional(), account_ids: z.array(z.string().uuid()).optional(), resource_ids: z.array(z.string().uuid()).optional(),
  tags: z.record(z.string().max(200), z.string().max(500)).optional(),
}).strict();
const exclusionSchema = z.object({
  resource_ids: z.array(z.string().uuid()).optional(), series: strList.optional(), environments: strList.optional(),
  os_types: strList.optional(), tags: z.record(z.string(), z.string()).optional(),
}).strict();

const ruleSchema = z.object({
  name: z.string().trim().min(1).max(200),
  description: z.string().max(2000).default(''),
  enabled: z.boolean().default(true),
  kind: z.enum(['metric_threshold', 'heartbeat', 'service_state', 'synthetic', 'provider_state']),
  metric: z.string().regex(/^[a-z][a-z0-9_.]{0,127}$/).nullable().optional(),
  series_match: z.string().max(200).nullable().optional(),
  aggregation: z.enum(['avg', 'min', 'max', 'last']).default('avg'),
  operator: z.enum(['>', '>=', '<', '<=']).nullable().optional(),
  threshold: z.number().finite().nullable().optional(),
  recovery_threshold: z.number().finite().nullable().optional(),
  for_seconds: z.number().int().min(0).max(86400).default(300),
  consecutive: z.number().int().min(1).max(100).default(1),
  severity: z.enum(['warning', 'critical']),
  scope: scopeSchema.default({}),
  exclusions: exclusionSchema.default({}),
  escalation_policy_id: z.string().uuid().nullable().optional(),
}).superRefine((r, ctx) => {
  if (r.kind === 'metric_threshold') {
    if (!r.metric || !r.operator || r.threshold === null || r.threshold === undefined) {
      ctx.addIssue({ code: 'custom', message: 'metric, operator and threshold are required for metric rules', path: ['metric'] });
    }
    if (r.recovery_threshold != null && r.threshold != null && r.operator) {
      const up = r.operator.startsWith('>');
      if (up ? r.recovery_threshold > r.threshold : r.recovery_threshold < r.threshold) {
        ctx.addIssue({ code: 'custom', message: 'recovery threshold must be on the healthy side of the threshold (hysteresis)', path: ['recovery_threshold'] });
      }
    }
  }
  if (r.kind === 'heartbeat' && (r.threshold == null || r.threshold < 60)) {
    ctx.addIssue({ code: 'custom', message: 'heartbeat rules need a threshold of at least 60 seconds', path: ['threshold'] });
  }
});

const channelSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('email'), name: z.string().min(1).max(200), config: z.object({ to: z.array(z.string().email()).min(1).max(50) }) }),
  z.object({ kind: z.literal('slack'), name: z.string().min(1).max(200), secret: z.object({ webhook_url: z.string().url() }) }),
  z.object({ kind: z.literal('teams'), name: z.string().min(1).max(200), secret: z.object({ webhook_url: z.string().url() }) }),
  z.object({ kind: z.literal('webhook'), name: z.string().min(1).max(200), secret: z.object({ url: z.string().url(), signing_secret: z.string().min(16).max(200).optional() }) }),
  z.object({ kind: z.literal('telegram'), name: z.string().min(1).max(200), config: z.object({ chat_id: z.string().regex(/^-?\d+$|^@\w+$/) }),
    secret: z.object({ bot_token: z.string().regex(/^\d+:[A-Za-z0-9_-]{20,}$/, 'Invalid bot token format') }) }),
]);

const syntheticSchema = z.object({
  name: z.string().trim().min(1).max(200),
  kind: z.enum(['http', 'tcp', 'dns', 'tls', 'icmp']),
  target: z.string().trim().min(1).max(2000),
  interval_seconds: z.number().int().min(30).max(86400).default(60),
  probe_scope: z.enum(['public', 'private']).default('public'),
  locations: z.array(z.string().regex(/^[a-z0-9-]{1,40}$/)).min(1).max(10).default(['default']),
  enabled: z.boolean().default(true),
  resource_id: z.string().uuid().nullable().optional(),
  counts_for_liveness: z.boolean().default(false),
  config: z.object({
    method: z.enum(['GET', 'HEAD']).optional(),
    expected_status: z.array(z.number().int().min(100).max(599)).max(20).optional(),
    body_contains: z.string().max(500).optional(),
    timeout_seconds: z.number().int().min(1).max(60).optional(),
    follow_redirects: z.boolean().optional(),
    port: z.number().int().min(1).max(65535).optional(),
    record_type: z.enum(['A', 'AAAA', 'CNAME', 'MX', 'TXT']).optional(),
    expected_values: z.array(z.string().max(300)).max(20).optional(),
    warn_days: z.number().int().min(1).max(365).optional(),
    skip_tls_verify: z.boolean().optional(),
  }).strict().default({}),
});

const routes: FastifyPluginAsync = async (app) => {
  const { db, keys, control } = app.deps;

  // ---------------- alert rules ----------------
  app.get('/alert-rules', async (req) => {
    const s = requirePerm(req, 'read');
    return withScope(db, s, async (tx) => (await tx.query(`SELECT r.*,
        (SELECT count(*)::int FROM alert_instances a WHERE a.rule_id=r.id AND a.state='firing') AS firing
      FROM alert_rules r ORDER BY r.kind, r.name`)).rows);
  });
  app.post('/alert-rules', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const r = body(req, ruleSchema);
    return withScope(db, s, async (tx) => {
      const { rows } = await tx.query(`INSERT INTO alert_rules(org_id, name, description, enabled, kind, metric, series_match, aggregation, operator,
          threshold, recovery_threshold, for_seconds, consecutive, severity, scope, exclusions, escalation_policy_id, created_by)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18) RETURNING *`,
        [s.orgId, r.name, r.description, r.enabled, r.kind, r.metric ?? null, r.series_match ?? null, r.aggregation, r.operator ?? null,
          r.threshold ?? null, r.recovery_threshold ?? null, r.for_seconds, r.consecutive, r.severity, r.scope, r.exclusions,
          r.escalation_policy_id ?? null, s.userId]);
      await audit(tx, { ...s, action: 'alert_rule.created', targetType: 'alert_rule', targetId: rows[0].id, details: r, ip: req.ip });
      return rows[0];
    });
  });
  app.put('/alert-rules/:id', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const { id } = params(req, idParams);
    const r = body(req, ruleSchema);
    return withScope(db, s, async (tx) => {
      const { rows } = await tx.query(`UPDATE alert_rules SET name=$2, description=$3, enabled=$4, kind=$5, metric=$6, series_match=$7,
          aggregation=$8, operator=$9, threshold=$10, recovery_threshold=$11, for_seconds=$12, consecutive=$13, severity=$14, scope=$15,
          exclusions=$16, escalation_policy_id=$17, updated_at=now() WHERE id=$1 RETURNING *`,
        [id, r.name, r.description, r.enabled, r.kind, r.metric ?? null, r.series_match ?? null, r.aggregation, r.operator ?? null,
          r.threshold ?? null, r.recovery_threshold ?? null, r.for_seconds, r.consecutive, r.severity, r.scope, r.exclusions, r.escalation_policy_id ?? null]);
      if (!rows[0]) throw notFound();
      await audit(tx, { ...s, action: 'alert_rule.updated', targetType: 'alert_rule', targetId: id, details: r, ip: req.ip });
      return rows[0];
    });
  });
  app.delete('/alert-rules/:id', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const { id } = params(req, idParams);
    return withScope(db, s, async (tx) => {
      const { rowCount } = await tx.query(`DELETE FROM alert_rules WHERE id=$1`, [id]);
      if (!rowCount) throw notFound();
      await audit(tx, { ...s, action: 'alert_rule.deleted', targetType: 'alert_rule', targetId: id, ip: req.ip });
      return { ok: true };
    });
  });

  // ---------------- monitoring policy ----------------
  app.get('/monitoring-policy', async (req) => {
    const s = requirePerm(req, 'read');
    return withScope(db, s, async (tx) => (await tx.query(`SELECT * FROM monitoring_policies WHERE is_default`)).rows[0] ?? null);
  });
  app.put('/monitoring-policy', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const b = body(req, z.object({
      heartbeat_interval_s: z.number().int().min(10).max(3600),
      heartbeat_warning_s: z.number().int().min(20).max(86400),
      heartbeat_critical_s: z.number().int().min(30).max(86400),
      metrics_interval_s: z.number().int().min(10).max(3600),
      flap_window_s: z.number().int().min(60).max(86400),
      flap_threshold: z.number().int().min(2).max(100),
      watched_services: z.object({ linux: z.array(z.string().max(200)).max(100).default([]), windows: z.array(z.string().max(200)).max(100).default([]) }),
      discover_services: z.boolean(),
    }).refine((p) => p.heartbeat_interval_s < p.heartbeat_warning_s && p.heartbeat_warning_s < p.heartbeat_critical_s, {
      message: 'Require interval < warning < critical',
    }));
    return withScope(db, s, async (tx) => {
      const { rows } = await tx.query(`UPDATE monitoring_policies SET heartbeat_interval_s=$1, heartbeat_warning_s=$2, heartbeat_critical_s=$3,
          metrics_interval_s=$4, flap_window_s=$5, flap_threshold=$6, watched_services=$7, discover_services=$8 WHERE is_default RETURNING *`,
        [b.heartbeat_interval_s, b.heartbeat_warning_s, b.heartbeat_critical_s, b.metrics_interval_s, b.flap_window_s, b.flap_threshold,
          b.watched_services, b.discover_services]);
      await audit(tx, { ...s, action: 'monitoring_policy.updated', details: b, ip: req.ip });
      return rows[0];
    });
  });

  // ---------------- maintenance windows ----------------
  app.get('/maintenance-windows', async (req) => {
    const s = requirePerm(req, 'read');
    return withScope(db, s, async (tx) => (await tx.query(`SELECT m.*, u.display_name AS created_by_name,
        (m.starts_at <= now() AND m.ends_at > now()) AS active FROM maintenance_windows m LEFT JOIN users u ON u.id=m.created_by
      WHERE m.ends_at > now() - interval '30 days' ORDER BY m.starts_at DESC`)).rows);
  });
  app.post('/maintenance-windows', async (req) => {
    const s = requirePerm(req, 'maintenance.manage');
    const b = body(req, z.object({
      name: z.string().trim().min(1).max(200), starts_at: z.string().datetime(), ends_at: z.string().datetime(), scope: scopeSchema,
    }).refine((m) => new Date(m.ends_at) > new Date(m.starts_at), { message: 'ends_at must be after starts_at' })
      .refine((m) => new Date(m.ends_at).getTime() - new Date(m.starts_at).getTime() <= 30 * 86400e3, { message: 'Maximum window is 30 days' })
      .refine((m) => Object.values(m.scope).some((v) => v && (Array.isArray(v) ? v.length : Object.keys(v).length)), {
        message: 'A maintenance window must be scoped (organization-wide windows are not allowed)',
      }));
    return withScope(db, s, async (tx) => {
      const { rows } = await tx.query(`INSERT INTO maintenance_windows(org_id, name, starts_at, ends_at, scope, created_by)
        VALUES ($1,$2,$3,$4,$5,$6) RETURNING *`, [s.orgId, b.name, b.starts_at, b.ends_at, b.scope, s.userId]);
      await audit(tx, { ...s, action: 'maintenance.created', targetType: 'maintenance_window', targetId: rows[0].id, details: b, ip: req.ip });
      return rows[0];
    });
  });
  app.delete('/maintenance-windows/:id', async (req) => {
    const s = requirePerm(req, 'maintenance.manage');
    const { id } = params(req, idParams);
    return withScope(db, s, async (tx) => {
      // Ending a window early keeps the record for the audit trail.
      const { rowCount } = await tx.query(`UPDATE maintenance_windows SET ends_at = LEAST(ends_at, now()),
        starts_at = LEAST(starts_at, now() - interval '1 second') WHERE id=$1`, [id]);
      if (!rowCount) throw notFound();
      await audit(tx, { ...s, action: 'maintenance.ended', targetType: 'maintenance_window', targetId: id, ip: req.ip });
      return { ok: true };
    });
  });

  // ---------------- notification channels ----------------
  app.get('/notification-channels', async (req) => {
    const s = requirePerm(req, 'read');
    return withScope(db, s, async (tx) => (await tx.query(`SELECT id, kind, name, config, enabled, created_at, (secret_ciphertext IS NOT NULL) AS has_secret,
        (SELECT count(*) FILTER (WHERE status='failed')::int FROM notification_deliveries d WHERE d.channel_id=c.id AND d.created_at > now() - interval '7 days') AS failed_7d,
        (SELECT max(sent_at) FROM notification_deliveries d WHERE d.channel_id=c.id) AS last_sent_at
      FROM notification_channels c ORDER BY name`)).rows);
  });
  app.post('/notification-channels', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const b = body(req, channelSchema);
    const secret = 'secret' in b ? b.secret : undefined;
    if (secret && 'webhook_url' in secret) validateWebhookUrl(secret.webhook_url);
    if (secret && 'url' in secret) validateWebhookUrl(secret.url);
    const id = crypto.randomUUID();
    return withScope(db, s, async (tx) => {
      const blob = secret ? seal(keys, JSON.stringify(secret), channelAad(s.orgId, id)) : null;
      const { rows } = await tx.query(`INSERT INTO notification_channels(id, org_id, kind, name, config, secret_ciphertext, secret_key_id)
        VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id, kind, name, config, enabled`,
        [id, s.orgId, b.kind, b.name, 'config' in b ? b.config : {}, blob, blob ? keys.activeId : null]);
      await audit(tx, { ...s, action: 'channel.created', targetType: 'notification_channel', targetId: id, details: { kind: b.kind, name: b.name }, ip: req.ip });
      return rows[0];
    });
  });
  app.patch('/notification-channels/:id', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const { id } = params(req, idParams);
    const b = body(req, z.object({ enabled: z.boolean().optional(), name: z.string().min(1).max(200).optional() }));
    return withScope(db, s, async (tx) => {
      const { rows } = await tx.query(`UPDATE notification_channels SET enabled=coalesce($2,enabled), name=coalesce($3,name) WHERE id=$1
        RETURNING id, kind, name, config, enabled`, [id, b.enabled ?? null, b.name ?? null]);
      if (!rows[0]) throw notFound();
      await audit(tx, { ...s, action: 'channel.updated', targetType: 'notification_channel', targetId: id, details: b, ip: req.ip });
      return rows[0];
    });
  });
  app.delete('/notification-channels/:id', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const { id } = params(req, idParams);
    return withScope(db, s, async (tx) => {
      const { rowCount } = await tx.query(`DELETE FROM notification_channels WHERE id=$1`, [id]);
      if (!rowCount) throw notFound();
      await audit(tx, { ...s, action: 'channel.deleted', targetType: 'notification_channel', targetId: id, ip: req.ip });
      return { ok: true };
    });
  });
  app.post('/notification-channels/:id/test', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const { id } = params(req, idParams);
    await withScope(db, s, async (tx) => {
      if (!(await tx.query(`SELECT 1 FROM notification_channels WHERE id=$1`, [id])).rows[0]) throw notFound();
      await audit(tx, { ...s, action: 'channel.tested', targetType: 'notification_channel', targetId: id, ip: req.ip });
    });
    return control.testChannel(s.orgId, id);
  });

  // ---------------- escalation policies ----------------
  const stepSchema = z.array(z.object({ delay_seconds: z.number().int().min(0).max(7 * 86400), channel_ids: z.array(z.string().uuid()).max(20) })).max(10)
    .refine((st) => st.every((x, i) => i === 0 || x.delay_seconds > st[i - 1]!.delay_seconds), { message: 'Step delays must increase' });
  app.get('/escalation-policies', async (req) => {
    const s = requirePerm(req, 'read');
    return withScope(db, s, async (tx) => (await tx.query(`SELECT * FROM escalation_policies ORDER BY is_default DESC, name`)).rows);
  });
  app.put('/escalation-policies/:id', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const { id } = params(req, idParams);
    const b = body(req, z.object({ name: z.string().min(1).max(200), steps: stepSchema,
      repeat_interval_s: z.number().int().min(300).max(86400).nullable(), notify_on_resolve: z.boolean() }));
    return withScope(db, s, async (tx) => {
      const ids = b.steps.flatMap((x) => x.channel_ids);
      if (ids.length) {
        const { rows } = await tx.query(`SELECT count(*)::int AS n FROM notification_channels WHERE id = ANY($1)`, [ids]);
        if (rows[0].n !== new Set(ids).size) throw badRequest('Unknown notification channel in steps');
      }
      const { rows } = await tx.query(`UPDATE escalation_policies SET name=$2, steps=$3, repeat_interval_s=$4, notify_on_resolve=$5 WHERE id=$1 RETURNING *`,
        [id, b.name, JSON.stringify(b.steps), b.repeat_interval_s, b.notify_on_resolve]);
      if (!rows[0]) throw notFound();
      await audit(tx, { ...s, action: 'escalation_policy.updated', targetType: 'escalation_policy', targetId: id, details: b, ip: req.ip });
      return rows[0];
    });
  });

  // ---------------- synthetic checks ----------------
  app.get('/synthetic-checks', async (req) => {
    const s = requirePerm(req, 'read');
    return withScope(db, s, async (tx) => (await tx.query(`SELECT c.*, r.name AS resource_name,
        (SELECT round(100.0 * avg(ok::int), 2) FROM synthetic_results x WHERE x.check_id=c.id AND x.at > now() - interval '24 hours') AS success_24h,
        (SELECT round(avg(latency_ms)) FROM synthetic_results x WHERE x.check_id=c.id AND x.at > now() - interval '24 hours' AND ok) AS latency_24h
      FROM synthetic_checks c LEFT JOIN resources r ON r.id=c.resource_id ORDER BY c.name`)).rows);
  });
  app.get('/synthetic-checks/:id/results', async (req) => {
    const s = requirePerm(req, 'read');
    const { id } = params(req, idParams);
    const q = query(req, z.object({ hours: z.coerce.number().int().min(1).max(720).default(24) }));
    return withScope(db, s, async (tx) => (await tx.query(`SELECT at, location, ok, latency_ms, status_code, error FROM synthetic_results
      WHERE check_id=$1 AND at > now() - make_interval(hours => $2) ORDER BY at DESC LIMIT 2000`, [id, q.hours])).rows);
  });
  const saveCheck = async (req: any, id?: string) => {
    const s = requirePerm(req, 'monitoring.configure');
    const c = body(req, syntheticSchema);
    if (c.kind !== 'dns') validateTarget(c.kind === 'icmp' ? 'tcp-host' : c.kind, c.target, c.probe_scope);
    return withScope(db, s, async (tx) => {
      if (c.resource_id && !(await tx.query(`SELECT 1 FROM resources WHERE id=$1`, [c.resource_id])).rows[0]) throw badRequest('Unknown resource');
      const args = [s.orgId, c.name, c.kind, c.target, c.interval_seconds, c.probe_scope, c.locations, c.enabled, c.resource_id ?? null, c.counts_for_liveness, c.config];
      const { rows } = id
        ? await tx.query(`UPDATE synthetic_checks SET name=$2, kind=$3, target=$4, interval_seconds=$5, probe_scope=$6, locations=$7, enabled=$8,
            resource_id=$9, counts_for_liveness=$10, config=$11, next_run_at=now() WHERE id=$12 RETURNING *`, [...args, id])
        : await tx.query(`INSERT INTO synthetic_checks(org_id, name, kind, target, interval_seconds, probe_scope, locations, enabled, resource_id,
            counts_for_liveness, config) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING *`, args);
      if (!rows[0]) throw notFound();
      await audit(tx, { ...s, action: id ? 'synthetic.updated' : 'synthetic.created', targetType: 'synthetic_check', targetId: rows[0].id, details: c, ip: req.ip });
      return rows[0];
    });
  };
  app.post('/synthetic-checks', (req) => saveCheck(req));
  app.put('/synthetic-checks/:id', (req) => saveCheck(req, params(req, idParams).id));
  app.delete('/synthetic-checks/:id', async (req) => {
    const s = requirePerm(req, 'monitoring.configure');
    const { id } = params(req, idParams);
    return withScope(db, s, async (tx) => {
      const { rowCount } = await tx.query(`DELETE FROM synthetic_checks WHERE id=$1`, [id]);
      if (!rowCount) throw notFound();
      await audit(tx, { ...s, action: 'synthetic.deleted', targetType: 'synthetic_check', targetId: id, ip: req.ip });
      return { ok: true };
    });
  });
};

export default routes;
