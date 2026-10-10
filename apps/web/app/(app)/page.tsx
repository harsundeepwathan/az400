'use client';
import { AlertOctagon, CheckCircle2, ServerCog } from 'lucide-react';
import Link from 'next/link';
import { useMemo } from 'react';
import { TimeChart, cssVar } from '@/components/chart';
import { PageHeader } from '@/components/shell';
import { IncidentStatus, Meter, SeverityBadge, StateBadge } from '@/components/status';
import { Card, Empty, Skeleton, cx } from '@/components/ui';
import { duration, relTime } from '@/lib/format';
import { STATE_LABEL, type OpState } from '@/lib/state';
import { ProviderHealth, STATE_COLOR, useSummary } from '@/components/dashboard';

function Kpi({ label, value, tone, href, sub }: { label: string; value: number | undefined; tone?: 'good' | 'warning' | 'critical'; href?: string; sub?: string }) {
  const body = (
    <div className={cx('h-full rounded-lg border border-border bg-surface px-4 py-3 shadow-[var(--shadow)] transition-colors', href && 'hover:border-border-strong')}>
      <div className="text-xs text-ink-3">{label}</div>
      <div className={cx('mt-1 text-2xl font-semibold tracking-tight', tone === 'critical' && value ? 'text-critical-ink' : tone === 'warning' && value ? 'text-warning-ink' : tone === 'good' ? 'text-good-ink' : 'text-ink')}>
        {value ?? '—'}
      </div>
      {sub && <div className="mt-0.5 text-[11px] text-ink-3">{sub}</div>}
    </div>
  );
  return href ? <Link href={href} className="block">{body}</Link> : body;
}

export default function Overview() {
  const q = useSummary();
  const d = q.data;
  const count = (...s: OpState[]) => d?.counts.filter((c) => s.includes(c.state)).reduce((a, c) => a + c.n, 0) ?? undefined;
  const total = d?.counts.reduce((a, c) => a + c.n, 0);

  const trend = useMemo(() => {
    if (!d) return [];
    return ['cpu.utilization', 'memory.utilization'].map((m, i) => ({
      name: m === 'cpu.utilization' ? 'CPU (fleet avg)' : 'Memory (fleet avg)',
      data: d.trend.filter((t) => t.metric === m).map((t) => [t.t, Math.round(t.avg * 10) / 10] as [string, number]),
      color: cssVar(`--series-${i + 1}`),
    }));
  }, [d]);

  const timeline = useMemo(() => {
    if (!d) return [];
    return (['down', 'critical', 'warning'] as OpState[]).map((s) => ({
      name: STATE_LABEL[s], type: 'bar' as const, stack: 'st', color: cssVar(STATE_COLOR[s]),
      data: [...new Set(d.timeline.map((t) => t.t))].map((t) => [t, d.timeline.find((x) => x.t === t && x.state === s)?.n ?? 0] as [string, number]),
    }));
  }, [d]);

  return (
    <div className="mx-auto max-w-[1600px]">
      <PageHeader title="Overview" subtitle={q.dataUpdatedAt ? `Updated ${relTime(new Date(q.dataUpdatedAt))} · refreshes every 30s` : undefined} />
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-6">
        <Kpi label="Monitored resources" value={total} href="/inventory" sub={d ? `${count('no_data', 'unknown') ?? 0} without data · ${count('stopped') ?? 0} stopped` : undefined} />
        <Kpi label="Healthy" value={count('healthy')} tone="good" href="/inventory?state=healthy" />
        <Kpi label="Warning" value={count('warning')} tone="warning" href="/inventory?state=warning" />
        <Kpi label="Critical" value={count('critical')} tone="critical" href="/inventory?state=critical" />
        <Kpi label="Down (confirmed)" value={count('down')} tone="critical" href="/inventory?state=down" sub="independent signals agree" />
        <Kpi label="Unacknowledged incidents" value={d?.incidents.unacknowledged} tone="critical" href="/incidents" sub={d ? `${d.incidents.acknowledged} acknowledged` : undefined} />
      </div>

      {q.isLoading && <Skeleton className="mt-4 h-96" />}
      {d && (
        <div className="mt-4 grid grid-cols-1 gap-4 xl:grid-cols-3">
          <Card title="Active incidents" className="xl:col-span-2" bodyClassName="p-0"
            actions={<Link href="/incidents" className="text-xs text-accent hover:underline">All incidents</Link>}>
            {d.critical.length === 0 ? (
              <Empty title="No active incidents" icon={<CheckCircle2 className="size-6 text-good" />} />
            ) : (
              <ul className="divide-y divide-border">
                {d.critical.map((i) => (
                  <li key={i.id}>
                    <Link href={`/incidents/${i.id}`} className="flex items-center gap-3 px-4 py-2.5 hover:bg-surface-2">
                      <SeverityBadge severity={i.severity} />
                      <div className="min-w-0 flex-1">
                        <div className="truncate font-medium">{i.title}</div>
                        <div className="truncate text-xs text-ink-3">{i.resource_name ? `${i.resource_name} · ${i.provider} · ${i.region ?? ''}` : 'Multiple resources'}</div>
                      </div>
                      <IncidentStatus status={i.status} />
                      <span className="tabular w-20 text-right text-xs text-ink-2" title="Duration">{duration(i.first_detected_at)}</span>
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card title="Health by cloud provider">
            <ProviderHealth data={d.by_provider} />
          </Card>

          <Card title="Fleet CPU and memory" subtitle="Average across reporting resources, 5-minute buckets, last 6 hours" className="xl:col-span-2">
            {trend.some((s) => s.data.length) ? <TimeChart series={trend} unit="%" yMax={100} ariaLabel="Fleet CPU and memory utilization trend" height={200} />
              : <Empty title="No CPU or memory data in the last 6 hours" />}
          </Card>

          <Card title="Resources approaching disk capacity" bodyClassName="p-0" actions={<Link href="/reports?tab=disk" className="text-xs text-accent hover:underline">Forecast</Link>}>
            {d.disks.length === 0 ? <Empty title="No volume data">Disk usage requires the Skywatch agent or a provider guest agent.</Empty> : (
              <ul className="divide-y divide-border">
                {d.disks.map((x) => (
                  <li key={x.id + x.series} className="px-4 py-2">
                    <Link href={`/resources/${x.id}`} className="flex items-center justify-between gap-2 text-[13px] hover:underline">
                      <span className="truncate">{x.name} <span className="font-mono text-[11px] text-ink-3">{String(x.series).replace('mount=', '')}</span></span>
                    </Link>
                    <Meter value={x.value} warn={80} crit={90} />
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card title="Health timeline" subtitle="Resources in a degraded state per hour, last 24 hours" className="xl:col-span-2">
            {d.timeline.length ? <TimeChart series={timeline} ariaLabel="Count of resources down, critical or warning per hour" height={160} valueFormatter={(v) => `${v}`} />
              : <Empty title="No state history yet" />}
          </Card>

          <Card title="Service health" subtitle={`${d.services.monitored} required services monitored`} bodyClassName="p-0">
            <div className="flex gap-6 px-4 py-3 text-sm">
              <span><span className="font-semibold text-good-ink">{d.services.ok}</span> <span className="text-ink-3">running as expected</span></span>
              <span><span className={cx('font-semibold', d.services.failing ? 'text-critical-ink' : 'text-ink')}>{d.services.failing}</span> <span className="text-ink-3">not in expected state</span></span>
            </div>
            {d.failing_services.length > 0 && (
              <ul className="divide-y divide-border border-t border-border">
                {d.failing_services.map((s) => (
                  <li key={s.id}>
                    <Link href={`/resources/${s.resource_id}?tab=services`} className="flex items-center gap-2 px-4 py-2 hover:bg-surface-2">
                      <AlertOctagon className="size-3.5 text-critical" aria-hidden />
                      <span className="min-w-0 flex-1 truncate"><span className="font-medium">{s.display_name ?? s.name}</span> <span className="text-ink-3">on {s.resource_name}</span></span>
                      <span className="text-xs text-critical-ink">{s.current_state ?? 'unknown'}</span>
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card title="Top CPU consumers" bodyClassName="p-0">
            <TopList rows={d.top_cpu} />
          </Card>
          <Card title="Top memory consumers" bodyClassName="p-0">
            <TopList rows={d.top_memory} />
          </Card>
          <Card title="Recent incidents" bodyClassName="p-0">
            <ul className="divide-y divide-border">
              {d.recent.map((i) => (
                <li key={i.id}>
                  <Link href={`/incidents/${i.id}`} className="flex items-center gap-2 px-4 py-2 hover:bg-surface-2">
                    <span className="min-w-0 flex-1 truncate">{i.title}</span>
                    <IncidentStatus status={i.status} />
                    <span className="w-16 text-right text-xs text-ink-3">{relTime(i.first_detected_at)}</span>
                  </Link>
                </li>
              ))}
              {d.recent.length === 0 && <Empty title="No incidents recorded" />}
            </ul>
          </Card>

          <Card title="Integrations" className="xl:col-span-3" bodyClassName="p-0" actions={<Link href="/platform" className="text-xs text-accent hover:underline">Monitoring health</Link>}>
            <div className="grid grid-cols-1 divide-y divide-border md:grid-cols-3 md:divide-x md:divide-y-0">
              {d.accounts.map((a) => (
                <Link key={a.id} href={`/accounts/${a.id}`} className="flex items-center gap-3 px-4 py-2.5 hover:bg-surface-2">
                  <ServerCog className="size-4 text-ink-3" aria-hidden />
                  <div className="min-w-0 flex-1">
                    <div className="truncate font-medium">{a.name}</div>
                    <div className="truncate text-xs text-ink-3">{a.status === 'active' ? `Last collection ${relTime(a.last_success_at)}` : a.status_reason ?? a.status}</div>
                  </div>
                  <StateBadge size="sm" state={a.status === 'active' ? 'healthy' : a.status === 'disabled' || a.status === 'pending' ? 'no_data' : a.status === 'degraded' ? 'warning' : 'critical'} />
                </Link>
              ))}
              {d.accounts.length === 0 && <Empty title="No cloud accounts connected"><Link href="/accounts/new" className="text-accent hover:underline">Connect a cloud account</Link></Empty>}
            </div>
          </Card>
        </div>
      )}
    </div>
  );
}

function TopList({ rows }: { rows: any[] }) {
  if (!rows.length) return <Empty title="No recent data" />;
  return (
    <ul className="divide-y divide-border">
      {rows.map((r) => (
        <li key={r.id} className="px-4 py-2">
          <Link href={`/resources/${r.id}`} className="block truncate text-[13px] hover:underline">{r.name}</Link>
          <Meter value={r.value} warn={85} crit={95} />
        </li>
      ))}
    </ul>
  );
}
