import type { FastifyPluginAsync, FastifyReply } from 'fastify';
import { z } from 'zod';
import { requirePerm } from '../auth/session.js';
import { withScope } from '../db.js';
import { computeAvailability, METHODOLOGY } from '../lib/availability.js';
import { toCsv } from '../lib/csv.js';
import { query, rangeSchema, resolveRange } from '../lib/http.js';
import { renderPdf } from '../lib/pdf.js';

const fmt = rangeSchema.extend({ format: z.enum(['json', 'csv', 'pdf']).default('json') });

interface Report {
  title: string;
  notes: string[];
  headers: string[];
  widths: number[];
  rows: unknown[][];
  json: unknown;
}

async function send(reply: FastifyReply, format: 'json' | 'csv' | 'pdf', name: string, r: Report, from: Date, to: Date) {
  const stamp = new Date().toISOString().slice(0, 10);
  if (format === 'csv') {
    return reply.header('Content-Type', 'text/csv; charset=utf-8')
      .header('Content-Disposition', `attachment; filename="skywatch-${name}-${stamp}.csv"`).send(toCsv(r.headers, r.rows));
  }
  if (format === 'pdf') {
    const pdf = await renderPdf({ title: r.title, subtitle: `Period ${from.toISOString()} – ${to.toISOString()}`, notes: r.notes,
      headers: r.headers, widths: r.widths, rows: r.rows.map((row) => row.map((c) => (c instanceof Date ? c.toISOString() : c == null ? '' : String(c)))) });
    return reply.header('Content-Type', 'application/pdf').header('Content-Disposition', `attachment; filename="skywatch-${name}-${stamp}.pdf"`).send(pdf);
  }
  return { title: r.title, notes: r.notes, from, to, data: r.json };
}

const pct = (n: number | null) => (n == null ? 'n/a' : n.toFixed(3) + '%');
const hours = (s: number) => (s / 3600).toFixed(2);

/** Least-squares slope (units per hour) of points [hoursSinceStart, value]. */
export function slope(points: [number, number][]): number | null {
  if (points.length < 2) return null;
  const n = points.length;
  const mx = points.reduce((a, p) => a + p[0], 0) / n;
  const my = points.reduce((a, p) => a + p[1], 0) / n;
  let num = 0, den = 0;
  for (const [x, y] of points) { num += (x - mx) * (y - my); den += (x - mx) ** 2; }
  return den === 0 ? null : num / den;
}

const routes: FastifyPluginAsync = async (app) => {
  const { db } = app.deps;

  app.get('/reports/availability', async (req, reply) => {
    const s = requirePerm(req, 'read');
    const q = query(req, fmt.extend({ critical_is_down: z.enum(['true', 'false']).default('false') }));
    const { from, to } = resolveRange({ ...q, range: q.range ?? '30d' });
    const policy = { criticalIsDown: q.critical_is_down === 'true' };
    const rows = await withScope(db, s, async (tx) => {
      const res = (await tx.query(`SELECT id, name, provider, resource_type, region, environment FROM resources WHERE deleted_at IS NULL AND monitoring_enabled ORDER BY name`)).rows;
      const hist = (await tx.query(`SELECT resource_id, state, started_at, ended_at FROM resource_state_history
        WHERE started_at < $2 AND coalesce(ended_at, now()) > $1`, [from, to])).rows;
      const byRes = new Map<string, any[]>();
      for (const h of hist) (byRes.get(h.resource_id) ?? byRes.set(h.resource_id, []).get(h.resource_id)!).push({ state: h.state, start: h.started_at, end: h.ended_at });
      return res.map((r) => ({ ...r, ...computeAvailability(byRes.get(r.id) ?? [], from, to, policy) }));
    });
    const observed = rows.filter((r) => r.percent != null);
    const fleet = observed.length ? observed.reduce((a, r) => a + r.available_seconds, 0) / observed.reduce((a, r) => a + r.available_seconds + r.unavailable_seconds, 0) * 100 : null;
    return send(reply, q.format, 'availability', {
      title: 'Availability report',
      notes: [METHODOLOGY, policy.criticalIsDown ? 'Strict policy: Critical counted as unavailable.' : 'Standard policy: Critical counted as available (degraded).',
        `Fleet availability (time-weighted over observed resources): ${pct(fleet)}`],
      headers: ['Resource', 'Provider', 'Type', 'Region', 'Environment', 'Availability', 'Unavailable (h)', 'Excluded (h)', 'Coverage'],
      widths: [150, 70, 90, 80, 80, 70, 70, 70, 60],
      rows: rows.map((r) => [r.name, r.provider, r.resource_type, r.region, r.environment, pct(r.percent), hours(r.unavailable_seconds), hours(r.excluded_seconds), (r.coverage * 100).toFixed(1) + '%']),
      json: { fleet_percent: fleet, methodology: METHODOLOGY, policy, resources: rows },
    }, from, to);
  });

  app.get('/reports/incidents', async (req, reply) => {
    const s = requirePerm(req, 'read');
    const q = query(req, fmt);
    const { from, to } = resolveRange({ ...q, range: q.range ?? '30d' });
    const rows = await withScope(db, s, async (tx) => (await tx.query(`SELECT i.number, i.title, i.severity, i.status, i.first_detected_at, i.acknowledged_at,
        i.resolved_at, i.resolution, r.name AS resource, r.provider, extract(epoch from (coalesce(i.acknowledged_at, now()) - i.first_detected_at))::int AS tta_s,
        extract(epoch from (coalesce(i.resolved_at, now()) - i.first_detected_at))::int AS duration_s
      FROM incidents i LEFT JOIN resources r ON r.id = i.resource_id
      WHERE i.first_detected_at BETWEEN $1 AND $2 AND i.parent_incident_id IS NULL ORDER BY i.first_detected_at DESC`, [from, to])).rows);
    const acked = rows.filter((r) => r.acknowledged_at);
    const resolved = rows.filter((r) => r.resolved_at);
    const mtta = acked.length ? acked.reduce((a, r) => a + r.tta_s, 0) / acked.length : null;
    const mttr = resolved.length ? resolved.reduce((a, r) => a + r.duration_s, 0) / resolved.length : null;
    return send(reply, q.format, 'incidents', {
      title: 'Incident history',
      notes: [`${rows.length} incidents. MTTA ${mtta == null ? 'n/a' : (mtta / 60).toFixed(1) + ' min'} (acknowledged incidents only). ` +
        `MTTR ${mttr == null ? 'n/a' : (mttr / 60).toFixed(1) + ' min'} (resolved incidents only, detection to resolution).`],
      headers: ['#', 'Title', 'Severity', 'Status', 'Resource', 'Detected', 'Acknowledged', 'Resolved', 'Duration (min)'],
      widths: [30, 220, 55, 70, 100, 100, 100, 100, 60],
      rows: rows.map((r) => [r.number, r.title, r.severity, r.status + (r.resolution ? ` (${r.resolution})` : ''), r.resource, r.first_detected_at, r.acknowledged_at, r.resolved_at, (r.duration_s / 60).toFixed(1)]),
      json: { mtta_seconds: mtta, mttr_seconds: mttr, incidents: rows },
    }, from, to);
  });

  app.get('/reports/inventory', async (req, reply) => {
    const s = requirePerm(req, 'read');
    const q = query(req, fmt);
    const now = new Date();
    const rows = await withScope(db, s, async (tx) => (await tx.query(`SELECT r.name, r.provider, a.name AS account, r.external_account_id, r.resource_type,
        r.native_type, r.region, r.environment, r.os_type, r.os_name, r.power_state, r.operational_state, r.monitoring_enabled, r.discovered_at,
        r.last_telemetry_at, EXISTS (SELECT 1 FROM agents g WHERE g.resource_id = r.id AND g.status='active') AS agent
      FROM resources r LEFT JOIN cloud_accounts a ON a.id = r.cloud_account_id WHERE r.deleted_at IS NULL ORDER BY r.provider, r.name`)).rows);
    return send(reply, q.format, 'inventory', {
      title: 'Cloud inventory', notes: [`${rows.length} resources across ${new Set(rows.map((r) => r.provider)).size} providers.`],
      headers: ['Name', 'Provider', 'Account', 'Type', 'Region', 'Environment', 'OS', 'Power', 'State', 'Agent', 'Monitored'],
      widths: [140, 65, 110, 85, 75, 70, 70, 60, 60, 40, 50],
      rows: rows.map((r) => [r.name, r.provider, r.account, r.resource_type, r.region, r.environment, r.os_name ?? r.os_type, r.power_state, r.operational_state, r.agent ? 'yes' : 'no', r.monitoring_enabled ? 'yes' : 'no']),
      json: rows,
    }, now, now);
  });

  app.get('/reports/utilization', async (req, reply) => {
    const s = requirePerm(req, 'read');
    const q = query(req, fmt);
    const { from, to } = resolveRange({ ...q, range: q.range ?? '7d' });
    const rows = await withScope(db, s, async (tx) => (await tx.query(`SELECT r.name, r.provider, x.metric,
        round(avg(x.avg)::numeric, 1) AS avg, round(max(x.max)::numeric, 1) AS peak,
        round(percentile_cont(0.95) WITHIN GROUP (ORDER BY x.avg)::numeric, 1) AS p95, count(*)::int AS hours
      FROM metric_rollups_1h x JOIN resources r ON r.id = x.resource_id
      WHERE x.metric IN ('cpu.utilization','memory.utilization') AND x.series='' AND x.bucket BETWEEN $1 AND $2 AND r.deleted_at IS NULL
      GROUP BY 1,2,3 ORDER BY 3, 5 DESC`, [from, to])).rows);
    return send(reply, q.format, 'utilization', {
      title: 'Resource utilization', notes: ['Computed from hourly rollups: average of hourly means, p95 of hourly means, and peak of per-minute maxima.'],
      headers: ['Resource', 'Provider', 'Metric', 'Average %', 'p95 %', 'Peak %', 'Hours of data'],
      widths: [180, 80, 130, 70, 70, 70, 80],
      rows: rows.map((r) => [r.name, r.provider, r.metric, r.avg, r.p95, r.peak, r.hours]),
      json: rows,
    }, from, to);
  });

  // Disk capacity with a linear trend forecast (experimental): least-squares slope of
  // hourly utilization over the last 7 days; only reported with >= 24 hours of history.
  app.get('/reports/disk-capacity', async (req, reply) => {
    const s = requirePerm(req, 'read');
    const q = query(req, fmt);
    const to = new Date();
    const from = new Date(to.getTime() - 7 * 86400e3);
    const out = await withScope(db, s, async (tx) => {
      const latest = (await tx.query(`SELECT r.id, r.name, r.provider, m.series, m.value, m.ts,
          (SELECT value FROM metric_latest t WHERE t.resource_id=m.resource_id AND t.metric='disk.total_bytes' AND t.series=m.series) AS total_bytes
        FROM metric_latest m JOIN resources r ON r.id=m.resource_id WHERE m.metric='disk.utilization' AND r.deleted_at IS NULL ORDER BY m.value DESC`)).rows;
      const hist = (await tx.query(`SELECT resource_id, series, bucket, avg FROM metric_rollups_1h
        WHERE metric='disk.utilization' AND bucket > $1 ORDER BY bucket`, [from])).rows;
      const byKey = new Map<string, [number, number][]>();
      for (const h of hist) {
        const k = h.resource_id + '|' + h.series;
        (byKey.get(k) ?? byKey.set(k, []).get(k)!).push([(new Date(h.bucket).getTime() - from.getTime()) / 3600e3, Number(h.avg)]);
      }
      return latest.map((l) => {
        const pts = byKey.get(l.id + '|' + l.series) ?? [];
        const span = pts.length ? pts[pts.length - 1]![0] - pts[0]![0] : 0;
        const sl = pts.length >= 24 && span >= 24 ? slope(pts) : null;
        let forecast: string;
        let days: number | null = null;
        if (sl === null) forecast = 'insufficient history';
        else if (sl <= 0.0005) forecast = 'stable or decreasing';
        else { days = (100 - l.value) / sl / 24; forecast = days > 365 ? '> 1 year' : `${days.toFixed(1)} days`; }
        return { ...l, mount: l.series.replace(/^mount=/, ''), growth_pct_per_day: sl === null ? null : sl * 24, days_to_full: days, forecast };
      });
    });
    return send(reply, q.format, 'disk-capacity', {
      title: 'Disk capacity', notes: ['Forecast (experimental): linear least-squares trend of hourly utilization over the last 7 days; requires at least 24 hours of history. Sudden growth or cleanup jobs make linear forecasts unreliable.'],
      headers: ['Resource', 'Volume', 'Used %', 'Size (GiB)', 'Growth %/day', 'Time to full'],
      widths: [180, 140, 60, 70, 80, 120],
      rows: out.map((r) => [r.name, r.mount, Number(r.value).toFixed(1), r.total_bytes ? (r.total_bytes / 2 ** 30).toFixed(1) : '', r.growth_pct_per_day?.toFixed(3) ?? '', r.forecast]),
      json: out,
    }, from, to);
  });

  app.get('/reports/services', async (req, reply) => {
    const s = requirePerm(req, 'read');
    const q = query(req, fmt);
    const { from, to } = resolveRange({ ...q, range: q.range ?? '30d' });
    const rows = await withScope(db, s, async (tx) => (await tx.query(`SELECT r.name AS resource, c.platform, c.name, c.display_name, c.expected_state, c.current_state,
        count(e.id) FILTER (WHERE e.to_state IN ('stopped','failed'))::int AS failures, max(e.at) FILTER (WHERE e.to_state IN ('stopped','failed')) AS last_failure
      FROM service_checks c JOIN resources r ON r.id = c.resource_id LEFT JOIN service_events e ON e.service_id = c.id AND e.at BETWEEN $1 AND $2
      WHERE c.expected_state <> 'any' GROUP BY 1,2,3,4,5,6 ORDER BY failures DESC, resource`, [from, to])).rows);
    return send(reply, q.format, 'services', {
      title: 'Service failures', notes: ['Counts transitions of required services into stopped or failed during the period.'],
      headers: ['Resource', 'Platform', 'Service', 'Expected', 'Current', 'Failures', 'Last failure'],
      widths: [140, 60, 180, 60, 60, 60, 140],
      rows: rows.map((r) => [r.resource, r.platform, r.display_name ?? r.name, r.expected_state, r.current_state, r.failures, r.last_failure]),
      json: rows,
    }, from, to);
  });
};

export default routes;
