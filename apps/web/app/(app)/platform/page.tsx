'use client';
import { useQuery } from '@tanstack/react-query';
import { TimeChart, cssVar } from '@/components/chart';
import { PageHeader } from '@/components/shell';
import { Card, Empty, ErrorNote, KV, Skeleton, Table, Td, Th, cx } from '@/components/ui';
import { api } from '@/lib/api';
import { relTime } from '@/lib/format';

export default function Platform() {
  const q = useQuery({ queryKey: ['platform'], queryFn: () => api.get<any>('/platform/health'), refetchInterval: 20_000 });
  if (q.error) return <ErrorNote error={q.error} />;
  if (!q.data) return <Skeleton className="h-96" />;
  const d = q.data;
  const runs = [
    { name: 'Successful runs', type: 'bar' as const, stack: 'r', color: cssVar('--series-1'), data: d.runs.map((r: any) => [r.t, r.runs - r.errors - r.throttled]) },
    { name: 'Errors', type: 'bar' as const, stack: 'r', color: cssVar('--critical'), data: d.runs.map((r: any) => [r.t, r.errors]) },
    { name: 'Throttled', type: 'bar' as const, stack: 'r', color: cssVar('--warning'), data: d.runs.map((r: any) => [r.t, r.throttled]) },
  ];
  const overdue = d.jobs.filter((j: any) => j.overdue).length;
  return (
    <div className="mx-auto max-w-[1400px] space-y-4">
      <PageHeader title="Monitoring health" subtitle="The monitoring platform watches itself. A failing collector degrades the integration; it never marks customer resources down." />
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <Card title="Pipeline">
          <KV items={[
            ['Agent ingestion', d.ingest.last_received ? `last heartbeat ${relTime(d.ingest.last_received)} · ${d.ingest.last_5m} in 5 min` : 'no agent heartbeats received'],
            ['Overdue collection jobs', <span key="o" className={overdue ? 'text-critical-ink' : ''}>{overdue}</span>],
            ['Notifications (24h)', d.deliveries.length ? d.deliveries.map((x: any) => `${x.n} ${x.status}`).join(' · ') : 'none'],
          ]} />
        </Card>
        <Card title="Platform instances" className="lg:col-span-2" bodyClassName="p-0">
          <Table><thead><tr><Th>Instance</Th><Th>Roles</Th><Th>Version</Th><Th>Heartbeat</Th></tr></thead>
            <tbody>{d.instances.map((i: any) => (
              <tr key={i.instance_id}><Td className="font-mono text-[12px]">{i.instance_id}</Td><Td className="text-xs">{i.roles.join(', ')}</Td><Td className="text-xs">{i.version}</Td>
                <Td className={cx('text-xs', i.alive ? 'text-good-ink' : 'text-critical-ink')}>{i.alive ? '● alive' : '● silent'} · {relTime(i.last_heartbeat)}</Td></tr>))}</tbody></Table>
        </Card>
        <Card title="Collector runs per hour (24h)" className="lg:col-span-3">
          {d.runs.length ? <TimeChart series={runs} ariaLabel="Collector runs per hour by outcome" valueFormatter={(v) => `${v}`} height={170} /> : <Empty title="No collector runs yet" />}
        </Card>
        <Card title="Collection jobs" className="lg:col-span-2" bodyClassName="p-0">
          <Table className="max-h-96"><thead><tr><Th>Account</Th><Th>Job</Th><Th>Last status</Th><Th>Last run</Th><Th>Next run</Th><Th>Failures</Th><Th>Duration</Th></tr></thead>
            <tbody>{d.jobs.map((j: any, n: number) => (
              <tr key={n}><Td className="text-xs">{j.account_name}</Td><Td className="text-xs">{j.kind}</Td>
                <Td><span className={cx('text-xs font-medium', j.last_status === 'ok' ? 'text-good-ink' : j.last_status === 'skipped' || !j.last_status ? 'text-ink-3' : 'text-critical-ink')} title={j.last_error ?? ''}>{j.last_status ?? 'pending'}</span></Td>
                <Td className="text-xs text-ink-2">{relTime(j.last_finished_at)}</Td><Td className={cx('text-xs', j.overdue ? 'text-critical-ink' : 'text-ink-2')}>{relTime(j.next_run_at)}</Td>
                <Td className="tabular text-xs">{j.consecutive_failures}</Td><Td className="tabular text-xs">{j.last_duration_ms != null ? `${j.last_duration_ms} ms` : '—'}</Td></tr>))}</tbody></Table>
        </Card>
        <Card title="Agent versions" bodyClassName="p-0">
          {d.agent_versions.length === 0 ? <Empty title="No agents" /> : (
            <Table><thead><tr><Th>Version</Th><Th>Agents</Th><Th>Reporting</Th></tr></thead>
              <tbody>{d.agent_versions.map((v: any) => <tr key={v.agent_version}><Td>{v.agent_version}</Td><Td className="tabular">{v.n}</Td><Td className="tabular">{v.reporting}</Td></tr>)}</tbody></Table>
          )}
        </Card>
      </div>
    </div>
  );
}
