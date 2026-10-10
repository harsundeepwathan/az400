'use client';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ArrowLeft, Link2 } from 'lucide-react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { useMemo, useState } from 'react';
import { TimeChart, cssVar } from '@/components/chart';
import { useCan, useMe } from '@/components/session';
import { IncidentStatus, ProviderTag, SeverityBadge, StateBadge } from '@/components/status';
import { Button, Card, Empty, ErrorNote, KV, Select, Skeleton, Table, Td, Textarea, Th, cx } from '@/components/ui';
import { api, qs } from '@/lib/api';
import { dateTime, duration, metricLabel, relTime } from '@/lib/format';

export default function IncidentDetail() {
  const { id } = useParams<{ id: string }>();
  const me = useMe();
  const canManage = useCan('incident.manage');
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['incident', id], queryFn: () => api.get<any>(`/incidents/${id}`), refetchInterval: 15_000 });
  const members = useQuery({ queryKey: ['members'], queryFn: () => api.get<any[]>('/members'), enabled: canManage });
  const [note, setNote] = useState('');
  const act = useMutation({
    mutationFn: (v: { action: string; body?: object }) => api.post(`/incidents/${id}/${v.action}`, v.body ?? {}),
    onSuccess: () => { setNote(''); qc.invalidateQueries({ queryKey: ['incident', id] }); qc.invalidateQueries({ queryKey: ['incidents'] }); qc.invalidateQueries({ queryKey: ['summary'] }); },
  });
  if (q.error) return <ErrorNote error={q.error} />;
  if (!q.data) return <Skeleton className="h-96" />;
  const { incident: i, alerts, timeline, children, notifications, recent_changes } = q.data;

  return (
    <div className="mx-auto max-w-[1400px]">
      <Link href="/incidents" className="mb-3 inline-flex items-center gap-1 text-xs text-ink-3 hover:text-ink"><ArrowLeft className="size-3.5" />Incidents</Link>
      <div className="mb-4 flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="tabular text-sm text-ink-3">INC-{i.number}</span>
            <SeverityBadge severity={i.severity} /><IncidentStatus status={i.status} />
          </div>
          <h1 className="mt-1 text-lg font-semibold tracking-tight">{i.title}</h1>
          <p className="text-[13px] text-ink-2">{i.trigger_summary}</p>
        </div>
        {canManage && i.status !== 'resolved' && (
          <div className="flex flex-wrap gap-2">
            {i.status === 'open' && <Button variant="primary" onClick={() => act.mutate({ action: 'ack' })} disabled={act.isPending}>Acknowledge</Button>}
            {i.assigned_to !== me.user.id && <Button onClick={() => act.mutate({ action: 'assign', body: { user_id: me.user.id } })}>Assign to me</Button>}
            <Button onClick={() => { if (confirm('Resolve manually? Alerts still firing will not reopen this incident.')) act.mutate({ action: 'resolve', body: { note: note || undefined } }); }}>Resolve</Button>
          </div>
        )}
      </div>
      <ErrorNote error={act.error} />
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          {i.parent_incident_id && (
            <div className="flex gap-2 rounded-md border border-border bg-surface-2 px-3 py-2 text-xs text-ink-2">
              <Link2 className="size-4 shrink-0" aria-hidden />
              <span>Grouped under <Link className="font-medium text-accent hover:underline" href={`/incidents/${i.parent_incident_id}`}>{i.parent_title}</Link>. {i.correlation_note}</span>
            </div>
          )}
          <Card title="Alerts" bodyClassName="p-0">
            {alerts.length === 0 ? <Empty title="No alert instances">{i.dedup_key.startsWith('account:') ? 'This incident tracks the health of a cloud integration.' : i.dedup_key.startsWith('burst:') ? 'This incident groups related incidents; see below.' : null}</Empty> : (
              <Table><thead><tr><Th>Rule</Th><Th>State</Th><Th>Detail</Th><Th>Since</Th></tr></thead>
                <tbody>{alerts.map((a: any) => (
                  <tr key={a.id}><Td><div className="font-medium">{a.rule_name}</div><div className="text-xs text-ink-3">{a.kind}{a.series ? ` · ${a.series}` : ''}</div></Td>
                    <Td><span className={cx('text-xs font-medium', a.state === 'firing' ? 'text-critical-ink' : 'text-good-ink')}>{a.state}</span></Td>
                    <Td className="text-xs">{a.summary}</Td><Td className="whitespace-nowrap text-xs text-ink-2">{relTime(a.firing_since)}</Td></tr>))}</tbody></Table>
            )}
          </Card>
          {i.resource_id && <Telemetry incident={i} alerts={alerts} />}
          {children.length > 0 && (
            <Card title={`Related incidents (${children.length})`} subtitle={i.correlation_note} bodyClassName="p-0">
              <ul className="divide-y divide-border">{children.map((c: any) => (
                <li key={c.id}><Link href={`/incidents/${c.id}`} className="flex items-center gap-2 px-4 py-2 hover:bg-surface-2">
                  <SeverityBadge severity={c.severity} /><span className="flex-1 truncate">{c.title}</span><IncidentStatus status={c.status} /></Link></li>))}</ul>
            </Card>
          )}
          <Card title="Timeline" bodyClassName="p-0">
            <ol className="relative px-4 py-3">
              {timeline.map((e: any) => (
                <li key={e.id} className="relative border-l border-border pb-3 pl-4 last:pb-0">
                  <span aria-hidden className={cx('absolute -left-[5px] top-1.5 size-2.5 rounded-full border-2 border-surface',
                    e.kind === 'resolved' || e.kind === 'alert_resolved' ? 'bg-good' : e.kind === 'opened' || e.kind === 'alert_firing' || e.kind === 'reopened' ? 'bg-critical' : 'bg-ink-3')} />
                  <div className="flex flex-wrap items-baseline gap-x-2 text-xs text-ink-3"><span className="tabular">{dateTime(e.at)}</span><span>{e.kind.replace('_', ' ')}</span>{e.actor && <span>· {e.actor}</span>}</div>
                  <div className="text-[13px]">{e.message}</div>
                </li>
              ))}
            </ol>
            {canManage && (
              <form className="flex gap-2 border-t border-border p-3" onSubmit={(e) => { e.preventDefault(); if (note.trim()) act.mutate({ action: 'comment', body: { note } }); }}>
                <Textarea aria-label="Add a note" rows={2} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Add a note to the timeline" />
                <Button type="submit" disabled={!note.trim() || act.isPending}>Comment</Button>
              </form>
            )}
          </Card>
        </div>
        <div className="space-y-4">
          <Card title="Details">
            <KV items={[
              ['Affected resource', i.resource_id ? <Link key="r" href={`/resources/${i.resource_id}`} className="text-accent hover:underline">{i.resource_name}</Link> : i.account_name ?? 'multiple'],
              ['Resource state', i.resource_state ? <StateBadge key="s" size="sm" state={i.resource_state} /> : '—'],
              ['Provider / region', i.provider ? <span key="p"><ProviderTag provider={i.provider} /> · {i.region ?? '—'}</span> : '—'],
              ['First detected', dateTime(i.first_detected_at)],
              ['Last observed', dateTime(i.last_observed_at)],
              ['Duration', duration(i.first_detected_at, i.resolved_at)],
              ['Acknowledged', i.acknowledged_at ? `${dateTime(i.acknowledged_at)} by ${i.acknowledged_by_name ?? '—'}` : 'no'],
              ['Owner', canManage && members.data ? (
                <Select key="o" aria-label="Owner" value={i.assigned_to ?? ''} onChange={(e) => act.mutate({ action: 'assign', body: { user_id: e.target.value || null } })} className="h-7 w-full">
                  <option value="">Unassigned</option>{members.data.map((m) => <option key={m.id} value={m.id}>{m.display_name}</option>)}
                </Select>) : i.assignee_name ?? 'unassigned'],
              ['Resolved', i.resolved_at ? `${dateTime(i.resolved_at)} (${i.resolution})` : '—'],
            ]} />
          </Card>
          <Card title="What changed before" subtitle="Infrastructure events in the 2 hours before detection. Context only, not an asserted cause." bodyClassName="p-0">
            {recent_changes.length === 0 ? <Empty title="No recorded changes" /> : (
              <ul className="divide-y divide-border">{recent_changes.map((c: any, n: number) => (
                <li key={n} className="px-4 py-2"><div className="text-xs text-ink-3">{dateTime(c.at)} · {c.source}</div><div className="text-[13px]">{c.message}</div></li>))}</ul>
            )}
          </Card>
          <Card title="Notifications" bodyClassName="p-0">
            {notifications.length === 0 ? <Empty title="No notifications sent">Configure an escalation policy under Notifications.</Empty> : (
              <ul className="divide-y divide-border">{notifications.map((d: any, n: number) => (
                <li key={n} className="flex items-center gap-2 px-4 py-2 text-xs">
                  <span className="flex-1">{d.channel} <span className="text-ink-3">({d.kind}) · {d.event}</span></span>
                  <span className={cx(d.status === 'sent' ? 'text-good-ink' : d.status === 'failed' ? 'text-critical-ink' : 'text-ink-2')} title={d.last_error ?? ''}>{d.status}</span>
                </li>))}</ul>
            )}
          </Card>
        </div>
      </div>
    </div>
  );
}

function Telemetry({ incident, alerts }: { incident: any; alerts: any[] }) {
  const metric = alerts.find((a) => a.metric)?.metric as string | undefined;
  const from = new Date(new Date(incident.first_detected_at).getTime() - 60 * 60e3).toISOString();
  const to = (incident.resolved_at ? new Date(new Date(incident.resolved_at).getTime() + 30 * 60e3) : new Date()).toISOString();
  const metrics = metric ?? 'cpu.utilization,memory.utilization';
  const q = useQuery({
    queryKey: ['inc-metrics', incident.id, metrics],
    queryFn: () => api.get<any>(`/resources/${incident.resource_id}/metrics` + qs({ metrics, from, to })),
  });
  const series = useMemo(() => (q.data?.series ?? []).slice(0, 6).map((s: any, i: number) => ({
    name: `${metricLabel(s.metric)}${s.series ? ' ' + s.series.replace('mount=', '') : ''}`, data: s.points.map((p: any) => [p[0], p[1]]), color: cssVar(`--series-${i + 1}`),
  })), [q.data]);
  const threshold = alerts.find((a) => a.metric === metric)?.threshold;
  return (
    <Card title="Supporting telemetry" subtitle={`1 hour before detection to ${incident.resolved_at ? '30 minutes after resolution' : 'now'}`}>
      {q.isLoading ? <Skeleton className="h-40" /> : series.length ? (
        <TimeChart series={series} ariaLabel="Metric values around the incident" unit={metric?.includes('utilization') ? '%' : ''}
          thresholds={threshold != null ? [{ value: threshold, label: `threshold ${threshold}`, severity: incident.severity }] : []} />
      ) : <Empty title="No metric data for this window" />}
    </Card>
  );
}
