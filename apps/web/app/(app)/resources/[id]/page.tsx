'use client';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ArrowLeft, Info } from 'lucide-react';
import Link from 'next/link';
import { useParams, useRouter, useSearchParams } from 'next/navigation';
import { Suspense, useMemo, useState } from 'react';
import { TimeChart, cssVar, type Series } from '@/components/chart';
import { useCan } from '@/components/session';
import { IncidentStatus, Meter, ProviderTag, SeverityBadge, StateBadge } from '@/components/status';
import { TimeRangePicker, type Range } from '@/components/time-range';
import { Button, Card, Empty, ErrorNote, Field, Input, KV, Mono, Select, Skeleton, Table, Tabs, Td, Th, cx } from '@/components/ui';
import { api, qs } from '@/lib/api';
import { bytes, dateTime, duration, metricLabel, pct, rate, relTime } from '@/lib/format';
import { PROVIDER_LABEL, TYPE_LABEL } from '@/lib/state';

type Tab = 'overview' | 'metrics' | 'services' | 'availability' | 'events' | 'config';

function useResource(id: string) {
  return useQuery({ queryKey: ['resource', id], queryFn: () => api.get<any>(`/resources/${id}`), refetchInterval: 30_000 });
}

function Detail() {
  const { id } = useParams<{ id: string }>();
  const params = useSearchParams();
  const router = useRouter();
  const tab = (params.get('tab') as Tab) ?? 'overview';
  const q = useResource(id);
  if (q.error) return <ErrorNote error={q.error} />;
  if (!q.data) return <Skeleton className="h-96" />;
  const { resource: r, agent } = q.data;
  return (
    <div className="mx-auto max-w-[1500px]">
      <Link href="/inventory" className="mb-3 inline-flex items-center gap-1 text-xs text-ink-3 hover:text-ink"><ArrowLeft className="size-3.5" />Inventory</Link>
      <div className="mb-4 flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="truncate text-lg font-semibold tracking-tight">{r.name}</h1>
            <StateBadge state={r.operational_state} />
            {r.flapping && <span className="rounded bg-warning-soft px-1.5 py-0.5 text-[11px] text-warning-ink">flapping</span>}
            {!r.monitoring_enabled && <span className="rounded bg-neutral-soft px-1.5 py-0.5 text-[11px] text-ink-2">monitoring disabled</span>}
          </div>
          <p className="mt-1 text-[13px] text-ink-2">{r.state_reason}</p>
          <p className="mt-0.5 text-xs text-ink-3">
            <ProviderTag provider={r.provider} /> · {TYPE_LABEL[r.resource_type] ?? r.resource_type} · {r.region ?? 'no region'} · in this state for {duration(r.state_since)}
          </p>
        </div>
        <Tabs value={tab} onChange={(t) => router.replace(`?tab=${t}`, { scroll: false })} items={[
          { value: 'overview', label: 'Overview' }, { value: 'metrics', label: 'Metrics' }, { value: 'services', label: `Services (${q.data.services.filter((s: any) => s.expected_state !== 'any').length})` },
          { value: 'availability', label: 'Availability' }, { value: 'events', label: 'Events' }, { value: 'config', label: 'Configuration' },
        ]} />
      </div>
      {tab === 'overview' && <Overview data={q.data} />}
      {tab === 'metrics' && <Metrics id={id} gaps={r.metric_gaps} latest={q.data.latest} />}
      {tab === 'services' && <Services id={id} services={q.data.services} hasAgent={!!agent} osType={r.os_type} />}
      {tab === 'availability' && <Availability id={id} />}
      {tab === 'events' && <Events events={q.data.events} />}
      {tab === 'config' && <Config data={q.data} />}
    </div>
  );
}

function Signal({ label, ok, value, note }: { label: string; ok: boolean | null; value: string; note?: string }) {
  return (
    <div className="flex items-start gap-2.5 py-1.5">
      <span aria-hidden className={cx('mt-1.5 size-2 shrink-0 rounded-full', ok === null ? 'bg-surface-3' : ok ? 'bg-good' : 'bg-critical')} />
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2"><span className="text-ink-2">{label}</span><span className="text-right font-medium">{value}</span></div>
        {note && <div className="text-xs text-ink-3">{note}</div>}
      </div>
    </div>
  );
}

function Overview({ data }: { data: any }) {
  const { resource: r, agent, incidents, latest, checks } = data;
  const sig = r.signals ?? {};
  const latestOf = (m: string, series = '') => latest.find((l: any) => l.metric === m && l.series === series);
  const vols = latest.filter((l: any) => l.metric === 'disk.utilization');
  const hb = sig.agent ?? sig.guest_heartbeat;
  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
      <Card title="Health signals" subtitle="Independent signals combined into the operational state" className="lg:col-span-2">
        <div className="grid grid-cols-1 gap-x-8 md:grid-cols-2">
          <Signal label="Provider power state" ok={r.power_state === 'running' ? true : r.power_state === 'unknown' || r.power_state === 'not_applicable' ? null : false}
            value={r.provider_state_raw || r.power_state} note="Power state alone never implies the OS is responsive." />
          <Signal label="Provider health" ok={r.provider_health === 'available' ? true : r.provider_health === 'unknown' ? null : false}
            value={r.provider_health} note={r.provider_health_reason ?? (sig.provider_health_stale ? 'No fresh provider health data' : undefined)} />
          <Signal label="Skywatch agent heartbeat" ok={sig.agent ? sig.agent.status === 'ok' : null}
            value={sig.agent ? `${sig.agent.status}${agent?.last_heartbeat_at ? ' · ' + relTime(agent.last_heartbeat_at) : ''}` : 'no agent'}
            note={sig.agent?.missed ? `${sig.agent.missed} consecutive heartbeats missed` : agent?.last_heartbeat_latency_ms != null ? `latency ${agent.last_heartbeat_latency_ms} ms` : undefined} />
          <Signal label="Provider guest heartbeat" ok={sig.guest_heartbeat ? sig.guest_heartbeat.status === 'ok' : null}
            value={sig.guest_heartbeat ? `${sig.guest_heartbeat.status} · ${relTime(r.guest_heartbeat_at)}` : 'not configured'} note={r.guest_heartbeat_source ?? undefined} />
          <Signal label="Reachability checks" ok={sig.checks?.length ? sig.checks.every((c: any) => c.ok) : null}
            value={sig.checks?.length ? `${sig.checks.filter((c: any) => c.ok).length}/${sig.checks.length} passing` : 'none linked'}
            note={sig.checks?.length ? undefined : 'Link a TCP/HTTP check (counts for liveness) to confirm outages independently.'} />
          <Signal label="Required services" ok={sig.services?.length ? false : data.services.some((s: any) => s.expected_state !== 'any') ? true : null}
            value={sig.services?.length ? `${sig.services.length} not in expected state` : `${data.services.filter((s: any) => s.expected_state !== 'any').length} monitored`} />
        </div>
        {(sig.integration_degraded || sig.ingest_degraded) && (
          <div className="mt-3 flex gap-2 rounded-md border border-warning/40 bg-warning-soft px-3 py-2 text-xs text-warning-ink">
            <Info className="size-4 shrink-0" aria-hidden />
            <span>Monitoring degraded: {sig.integration_reason || 'agent ingestion pipeline unhealthy'}. Signals from this path are not trusted until it recovers.</span>
          </div>
        )}
        {sig.reasons?.length > 1 && (
          <div className="mt-3 border-t border-border pt-3">
            <div className="mb-1 text-xs font-medium text-ink-3">All findings</div>
            <ul className="list-disc space-y-0.5 pl-4 text-[13px]">{sig.reasons.map((x: string) => <li key={x}>{x}</li>)}</ul>
          </div>
        )}
        {hb?.status === 'missing' && !sig.host_confirmed_down && (
          <p className="mt-3 text-xs text-ink-3">Host outage is <strong>not confirmed</strong>: no independent signal corroborates the missing heartbeat.</p>
        )}
      </Card>

      <Card title="Current utilization">
        <div className="space-y-3">
          {[['cpu.utilization', 'CPU', 85, 95], ['memory.utilization', 'Memory', 85, 95]].map(([m, label, w, c]) => {
            const l = latestOf(m as string);
            return (
              <div key={m as string}>
                <div className="mb-0.5 flex justify-between text-xs"><span className="text-ink-2">{label}</span>
                  <span className="text-ink-3">{l ? `${l.source} · ${relTime(l.ts)}` : r.metric_gaps?.[m as string] ?? 'no data'}</span></div>
                <Meter value={l?.value} warn={w as number} crit={c as number} />
              </div>
            );
          })}
          <div>
            <div className="mb-1 text-xs text-ink-2">Volumes</div>
            {vols.length === 0 ? <p className="text-xs text-ink-3">{r.metric_gaps?.['disk.utilization'] ?? 'No filesystem data'}</p> :
              vols.map((v: any) => {
                const total = latestOf('disk.total_bytes', v.series);
                const used = latestOf('disk.used_bytes', v.series);
                return (
                  <div key={v.series} className="mb-1.5">
                    <div className="flex justify-between text-xs"><Mono>{v.series.replace('mount=', '')}</Mono><span className="text-ink-3">{used && total ? `${bytes(used.value)} of ${bytes(total.value)}` : ''}</span></div>
                    <Meter value={v.value} warn={80} crit={90} />
                  </div>
                );
              })}
          </div>
        </div>
      </Card>

      <Card title="Active and recent incidents" className="lg:col-span-2" bodyClassName="p-0">
        {incidents.length === 0 ? <Empty title="No incidents for this resource" /> : (
          <ul className="divide-y divide-border">
            {incidents.map((i: any) => (
              <li key={i.id}><Link href={`/incidents/${i.id}`} className="flex items-center gap-3 px-4 py-2 hover:bg-surface-2">
                <SeverityBadge severity={i.severity} /><span className="min-w-0 flex-1 truncate">{i.title}</span><IncidentStatus status={i.status} />
                <span className="w-24 text-right text-xs text-ink-3">{relTime(i.first_detected_at)}</span>
              </Link></li>
            ))}
          </ul>
        )}
      </Card>

      <Card title="Cloud metadata">
        <KV items={[
          ['Provider', PROVIDER_LABEL[r.provider] ?? r.provider],
          ['Account', r.account_name ?? (r.provider === 'onprem' ? 'agent-registered host' : '—')],
          ['Subscription / account', r.external_account_id ? <Mono>{r.external_account_id}</Mono> : '—'],
          ['Resource group', r.resource_group],
          ['Region', r.region],
          ['Native type', r.native_type],
          ['OS', r.os_name ?? r.os_type],
          ['Environment', r.environment],
          ['Discovered', dateTime(r.discovered_at)],
          ['Last telemetry', relTime(r.last_telemetry_at)],
          ['Provider ID', <Mono key="id" className="break-all text-[11px]">{r.provider_resource_id}</Mono>],
        ]} />
      </Card>

      {agent && (
        <Card title="Monitoring agent" className="lg:col-span-2">
          <KV items={[
            ['Agent', `${agent.hostname} · v${agent.agent_version} · ${agent.status}`],
            ['OS', `${agent.os_name ?? ''} ${agent.os_version ?? ''} (${agent.arch ?? ''}) ${agent.kernel_version ? '· kernel ' + agent.kernel_version : ''}`],
            ['Last heartbeat', `${relTime(agent.last_heartbeat_at)}${agent.last_heartbeat_latency_ms != null ? ` · ${agent.last_heartbeat_latency_ms} ms` : ''}`],
            ['Last boot', dateTime(agent.last_boot_at)],
            ['Local queue', `${agent.last_queue_depth ?? 0} batches · ${agent.last_dropped_batches ?? 0} dropped`],
            ['Collector errors', agent.collector_errors?.length ? agent.collector_errors.map((e: any) => `${e.collector}: ${e.error}`).join('; ') : 'none'],
            ['Credential rotated', relTime(agent.secret_rotated_at)],
          ]} />
        </Card>
      )}
      {checks.length > 0 && (
        <Card title="Linked synthetic checks" bodyClassName="p-0">
          <ul className="divide-y divide-border">{checks.map((c: any) => (
            <li key={c.id} className="flex items-center gap-2 px-4 py-2 text-[13px]">
              <span aria-hidden className={cx('size-2 rounded-full', c.last_ok ? 'bg-good' : c.last_ok === false ? 'bg-critical' : 'bg-surface-3')} />
              <span className="flex-1 truncate">{c.name}</span><span className="text-xs text-ink-3">{c.last_ok == null ? 'pending' : c.last_ok ? `${c.last_latency_ms} ms` : c.last_error}</span>
            </li>))}</ul>
        </Card>
      )}
    </div>
  );
}

function Metrics({ id, gaps, latest }: { id: string; gaps: Record<string, string>; latest: any[] }) {
  const [range, setRange] = useState<Range>({ range: '6h' });
  const metrics = 'cpu.utilization,memory.utilization,disk.utilization,net.in_bytes_per_sec,net.out_bytes_per_sec,disk.read_bytes_per_sec,disk.write_bytes_per_sec,cpu.load1';
  const q = useQuery({
    queryKey: ['metrics', id, range],
    queryFn: () => api.get<{ bucket: string; series: { metric: string; series: string; points: [string, number, number, number][] }[]; sources: { metric: string; source: string }[] }>(
      `/resources/${id}/metrics` + qs({ metrics, ...range })),
    refetchInterval: range.range === '1h' || range.range === '6h' ? 60_000 : false,
  });
  const by = (m: string) => q.data?.series.filter((s) => s.metric === m) ?? [];
  const toSeries = (m: string, name?: (s: string) => string): Series[] =>
    by(m).map((s, i) => ({ name: name ? name(s.series) : metricLabel(m), data: s.points.map((p) => [p[0], p[1]]), color: cssVar(`--series-${(i % 8) + 1}`) }));
  const src = (m: string) => q.data?.sources.filter((s) => s.metric === m).map((s) => s.source).join(', ');
  const gap = (m: string) => gaps?.[m];
  const net = [...toSeries('net.in_bytes_per_sec', () => 'Inbound'), ...toSeries('net.out_bytes_per_sec', () => 'Outbound')]
    .map((s, i) => ({ ...s, color: cssVar(`--series-${i + 1}`) }));
  const io = [...toSeries('disk.read_bytes_per_sec', () => 'Read'), ...toSeries('disk.write_bytes_per_sec', () => 'Write')]
    .map((s, i) => ({ ...s, color: cssVar(`--series-${i + 1}`) }));
  const vols = latest.filter((l) => l.metric === 'disk.utilization');

  const chart = (title: string, m: string, s: Series[], props: Partial<Parameters<typeof TimeChart>[0]> = {}) => (
    <Card title={title} subtitle={src(m) ? `Source: ${src(m)} · ${q.data?.bucket} resolution` : undefined}>
      {q.isLoading ? <Skeleton className="h-44" /> : s.some((x) => x.data.length) ? <TimeChart series={s} ariaLabel={`${title} over time`} {...props} />
        : <Empty title="No data in this range">{gap(m) ?? 'This metric has not been reported for the selected period.'}</Empty>}
    </Card>
  );

  return (
    <div>
      <div className="mb-3"><TimeRangePicker value={range} onChange={setRange} /></div>
      <ErrorNote error={q.error} />
      <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
        {chart('CPU utilization', 'cpu.utilization', toSeries('cpu.utilization'), { unit: '%', yMax: 100, thresholds: [{ value: 85, label: 'warn 85%', severity: 'warning' }, { value: 95, label: 'crit 95%', severity: 'critical' }] })}
        {chart('Memory utilization', 'memory.utilization', toSeries('memory.utilization'), { unit: '%', yMax: 100, thresholds: [{ value: 85, label: 'warn 85%', severity: 'warning' }] })}
        {chart('Disk utilization by volume', 'disk.utilization', toSeries('disk.utilization', (s) => s.replace('mount=', '')).slice(0, 8),
          { unit: '%', yMax: 100, showLegend: true, thresholds: [{ value: 80, label: 'warn 80%', severity: 'warning' }, { value: 90, label: 'crit 90%', severity: 'critical' }] })}
        {chart('Network throughput', 'net.in_bytes_per_sec', net, { valueFormatter: (v) => rate(v) })}
        {chart('Disk throughput', 'disk.read_bytes_per_sec', io, { valueFormatter: (v) => rate(v) })}
        {chart('Load average (1m)', 'cpu.load1', toSeries('cpu.load1'), { valueFormatter: (v) => v.toFixed(2) })}
      </div>
      {vols.length > 8 && <p className="mt-2 text-xs text-ink-3">Showing 8 of {vols.length} volumes in the chart; see Overview for all volumes.</p>}
    </div>
  );
}

function Services({ id, services, hasAgent, osType }: { id: string; services: any[]; hasAgent: boolean; osType: string | null }) {
  const canEdit = useCan('monitoring.configure');
  const qc = useQueryClient();
  const [filter, setFilter] = useState<'required' | 'all'>('required');
  const [name, setName] = useState('');
  const update = useMutation({
    mutationFn: (v: { sid: string; expected_state: string; critical: boolean }) => api.put(`/resources/${id}/services/${v.sid}`, v),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['resource', id] }),
  });
  const add = useMutation({
    mutationFn: () => api.post(`/resources/${id}/services`, { platform: osType === 'windows' ? 'windows' : 'systemd', name, expected_state: 'running', critical: true }),
    onSuccess: () => { setName(''); qc.invalidateQueries({ queryKey: ['resource', id] }); },
  });
  const rows = filter === 'required' ? services.filter((s) => s.expected_state !== 'any') : services;
  return (
    <Card title="Windows / Linux services" subtitle="Alerts fire only for services designated as required. Discovered services are informational."
      actions={<Tabs value={filter} onChange={setFilter} items={[{ value: 'required', label: 'Required' }, { value: 'all', label: `All (${services.length})` }]} />} bodyClassName="p-0">
      {!hasAgent && services.length === 0 ? <Empty title="No service data">Service monitoring requires the Skywatch agent on this host.</Empty> : (
        <Table>
          <thead><tr><Th>Service</Th><Th>State</Th><Th>Startup</Th><Th>PID</Th><Th>Restarts</Th><Th>Changed</Th><Th>Reported</Th><Th>Expectation</Th></tr></thead>
          <tbody>
            {rows.map((s) => {
              const bad = s.expected_state !== 'any' && s.current_state !== s.expected_state;
              return (
                <tr key={s.id} className={cx(bad && 'bg-critical-soft/50')}>
                  <Td><div className="font-medium">{s.display_name ?? s.name}</div><Mono className="text-ink-3">{s.name}</Mono></Td>
                  <Td><span className={cx('inline-flex items-center gap-1 text-xs font-medium', s.current_state === 'running' ? 'text-good-ink' : bad ? 'text-critical-ink' : 'text-ink-2')}>
                    <span aria-hidden className={cx('size-1.5 rounded-full', s.current_state === 'running' ? 'bg-good' : bad ? 'bg-critical' : 'bg-ink-3')} />{s.current_state ?? 'not reported'}{s.sub_state && s.sub_state !== s.current_state ? ` (${s.sub_state})` : ''}</span></Td>
                  <Td className="text-xs text-ink-2">{s.startup_type ?? '—'}</Td>
                  <Td className="tabular text-xs">{s.pid ?? '—'}</Td>
                  <Td className="tabular text-xs">{s.restart_count ?? '—'}</Td>
                  <Td className="text-xs text-ink-2">{relTime(s.last_change_at)}</Td>
                  <Td className="text-xs text-ink-2">{relTime(s.last_reported_at)}</Td>
                  <Td>
                    {canEdit ? (
                      <Select aria-label={`Expectation for ${s.name}`} value={s.expected_state === 'any' ? 'any' : s.critical ? 'running-critical' : s.expected_state}
                        onChange={(e) => {
                          const v = e.target.value;
                          update.mutate({ sid: s.id, expected_state: v === 'running-critical' ? 'running' : v, critical: v === 'running-critical' });
                        }}>
                        <option value="any">Informational</option>
                        <option value="running">Must run (warning)</option>
                        <option value="running-critical">Must run (critical)</option>
                        <option value="stopped">Must be stopped</option>
                      </Select>
                    ) : <span className="text-xs">{s.expected_state}</span>}
                  </Td>
                </tr>
              );
            })}
            {rows.length === 0 && <tr><Td colSpan={8}><Empty title="No required services">Switch to “All” to designate discovered services, or add one below.</Empty></Td></tr>}
          </tbody>
        </Table>
      )}
      {canEdit && (
        <form className="flex items-end gap-2 border-t border-border p-3" onSubmit={(e) => { e.preventDefault(); add.mutate(); }}>
          <Field label={`Require a ${osType === 'windows' ? 'Windows service' : 'systemd unit'} by name`}>
            <Input value={name} onChange={(e) => setName(e.target.value)} placeholder={osType === 'windows' ? 'e.g. MSSQLSERVER' : 'e.g. nginx.service'} className="w-72" />
          </Field>
          <Button type="submit" disabled={!name || add.isPending}>Add required service</Button>
          <ErrorNote error={add.error ?? update.error} />
        </form>
      )}
    </Card>
  );
}

function Availability({ id }: { id: string }) {
  const [range, setRange] = useState<Range>({ range: '7d' });
  const av = useQuery({ queryKey: ['availability', id, range], queryFn: () => api.get<any>(`/resources/${id}/availability` + qs(range)) });
  const hb = useQuery({ queryKey: ['heartbeats', id, range], queryFn: () => api.get<any>(`/resources/${id}/heartbeats` + qs(range)) });
  const hbSeries = useMemo<Series[]>(() => hb.data ? [{ name: 'Heartbeats received', type: 'bar', data: hb.data.points.map((p: any) => [p.t, p.n]) }] : [], [hb.data]);
  const a = av.data?.availability;
  return (
    <div className="space-y-4">
      <TimeRangePicker value={range} onChange={setRange} />
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <Card title="Availability">
          {!a ? <Skeleton className="h-24" /> : (
            <>
              <div className="text-3xl font-semibold tracking-tight">{a.percent == null ? 'n/a' : pct(a.percent, 3)}</div>
              <div className="mt-1 text-xs text-ink-3">coverage {(a.coverage * 100).toFixed(1)}% of the period</div>
              <KV items={[['Unavailable', `${(a.unavailable_seconds / 60).toFixed(1)} min`], ['Excluded', `${(a.excluded_seconds / 3600).toFixed(1)} h`]]} />
              <p className="mt-3 text-[11px] leading-relaxed text-ink-3">{av.data.methodology}</p>
            </>
          )}
        </Card>
        <Card title="State history" className="lg:col-span-2" bodyClassName="p-0">
          <Table className="max-h-80">
            <thead><tr><Th>State</Th><Th>From</Th><Th>Until</Th><Th>Duration</Th><Th>Reason</Th></tr></thead>
            <tbody>{(av.data?.intervals ?? []).slice().reverse().map((iv: any) => (
              <tr key={iv.started_at}><Td><StateBadge size="sm" state={iv.state} /></Td><Td className="text-xs">{dateTime(iv.started_at)}</Td>
                <Td className="text-xs">{iv.ended_at ? dateTime(iv.ended_at) : 'now'}</Td><Td className="tabular text-xs">{duration(iv.started_at, iv.ended_at)}</Td>
                <Td className="max-w-md truncate text-xs text-ink-2" title={iv.reason}>{iv.reason}</Td></tr>
            ))}</tbody>
          </Table>
        </Card>
        <Card title="Agent heartbeat history" subtitle={hb.data ? `Heartbeats received per ${hb.data.bucket}` : undefined} className="lg:col-span-3">
          {hbSeries[0]?.data.length ? <TimeChart series={hbSeries} ariaLabel="Heartbeats received over time" valueFormatter={(v) => `${v}`} height={150} />
            : <Empty title="No agent heartbeats in this range">Heartbeat history is recorded for hosts running the Skywatch agent.</Empty>}
        </Card>
      </div>
    </div>
  );
}

function Events({ events }: { events: any[] }) {
  return (
    <Card title="Infrastructure and OS events" subtitle="Provider activity log, agent-reported events" bodyClassName="p-0">
      {events.length === 0 ? <Empty title="No events recorded" /> : (
        <Table>
          <thead><tr><Th>Time</Th><Th>Source</Th><Th>Kind</Th><Th>Severity</Th><Th>Message</Th></tr></thead>
          <tbody>{events.map((e) => (
            <tr key={e.id}><Td className="whitespace-nowrap text-xs">{dateTime(e.at)}</Td><Td className="text-xs">{e.source}</Td><Td className="text-xs text-ink-2">{e.kind}</Td>
              <Td className="text-xs">{e.severity}</Td><Td>{e.message}</Td></tr>
          ))}</tbody>
        </Table>
      )}
    </Card>
  );
}

function Config({ data }: { data: any }) {
  const { resource: r, tags, relations } = data;
  const canEdit = useCan('monitoring.configure');
  const qc = useQueryClient();
  const toggle = useMutation({
    mutationFn: () => api.patch(`/resources/${r.id}`, { monitoring_enabled: !r.monitoring_enabled }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['resource', r.id] }),
  });
  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
      <Card title="Monitoring">
        <p className="mb-3 text-[13px] text-ink-2">Monitoring is <strong>{r.monitoring_enabled ? 'enabled' : 'disabled'}</strong>. Disabled resources stay in inventory but are not evaluated or alerted on.</p>
        {canEdit && <Button onClick={() => toggle.mutate()} disabled={toggle.isPending}>{r.monitoring_enabled ? 'Disable monitoring' : 'Enable monitoring'}</Button>}
        <ErrorNote error={toggle.error} />
        <div className="mt-4 text-xs font-medium text-ink-3">Metrics the provider cannot supply</div>
        {Object.keys(r.metric_gaps ?? {}).length === 0 ? <p className="text-xs text-ink-3">None reported.</p> : (
          <ul className="mt-1 space-y-1 text-xs">{Object.entries(r.metric_gaps).map(([m, why]) => <li key={m}><Mono>{m}</Mono>: <span className="text-ink-2">{why as string}</span></li>)}</ul>
        )}
      </Card>
      <Card title="Tags">
        {tags.length === 0 ? <p className="text-xs text-ink-3">No tags.</p> : (
          <div className="flex flex-wrap gap-1.5">{tags.map((t: any) => (
            <Link key={t.key} href={`/inventory?tag=${encodeURIComponent(t.value ? `${t.key}:${t.value}` : t.key)}`} className="rounded border border-border bg-surface-2 px-1.5 py-0.5 font-mono text-[11px] hover:border-border-strong">
              {t.key}{t.value ? `=${t.value}` : ''}
            </Link>))}</div>
        )}
      </Card>
      <Card title="Relationships" subtitle="Used for incident correlation" className="lg:col-span-2" bodyClassName="p-0">
        {relations.length === 0 ? <Empty title="No known relationships" /> : (
          <Table><thead><tr><Th>Relationship</Th><Th>Resource</Th><Th>Type</Th><Th>State</Th></tr></thead>
            <tbody>{relations.map((x: any) => (
              <tr key={x.id + x.kind}><Td className="text-xs">{x.direction === 'outgoing' ? `this is ${x.kind.replace('_', ' ')}` : `${x.kind.replace('_', ' ')} this`}</Td>
                <Td><Link href={`/resources/${x.id}`} className="hover:underline">{x.name}</Link></Td><Td className="text-xs">{TYPE_LABEL[x.resource_type] ?? x.resource_type}</Td>
                <Td><StateBadge size="sm" state={x.operational_state} /></Td></tr>))}</tbody></Table>
        )}
      </Card>
    </div>
  );
}

export default function Page() {
  return <Suspense><Detail /></Suspense>;
}

