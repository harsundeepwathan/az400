'use client';
import { useQuery } from '@tanstack/react-query';
import { CheckCircle2, Search } from 'lucide-react';
import Link from 'next/link';
import { useState } from 'react';
import { PageHeader } from '@/components/shell';
import { IncidentStatus, ProviderTag, SeverityBadge } from '@/components/status';
import { Card, Empty, ErrorNote, Input, Select, Skeleton, Table, Tabs, Td, Th, cx } from '@/components/ui';
import { api, qs } from '@/lib/api';
import { duration, relTime } from '@/lib/format';

export default function Incidents() {
  const [status, setStatus] = useState<'active' | 'resolved' | 'all'>('active');
  const [severity, setSeverity] = useState('');
  const [search, setSearch] = useState('');
  const q = useQuery({
    queryKey: ['incidents', status, severity, search],
    queryFn: () => api.get<any[]>('/incidents' + qs({ status, severity, q: search })),
    refetchInterval: 15_000,
    placeholderData: (p) => p,
  });
  return (
    <div className="mx-auto max-w-[1500px]">
      <PageHeader title="Incidents" subtitle="Alerts on the same resource are grouped; related failures are correlated by topology and timing." />
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <Tabs value={status} onChange={setStatus} items={[{ value: 'active', label: 'Active' }, { value: 'resolved', label: 'Resolved' }, { value: 'all', label: 'All' }]} />
        <Select aria-label="Severity" value={severity} onChange={(e) => setSeverity(e.target.value)}>
          <option value="">All severities</option><option value="critical">Critical</option><option value="warning">Warning</option>
        </Select>
        <div className="relative w-64">
          <Search className="pointer-events-none absolute left-2.5 top-2 size-4 text-ink-3" aria-hidden />
          <Input aria-label="Search incidents" placeholder="Search title or trigger" value={search} onChange={(e) => setSearch(e.target.value)} className="pl-8" />
        </div>
      </div>
      <ErrorNote error={q.error} />
      <Card bodyClassName="p-0">
        {q.isLoading ? <Skeleton className="m-4 h-64" /> : !q.data?.length ? (
          <Empty title={status === 'active' ? 'No active incidents' : 'No incidents'} icon={<CheckCircle2 className="size-6 text-good" />} />
        ) : (
          <Table>
            <thead><tr><Th>#</Th><Th>Severity</Th><Th>Incident</Th><Th>Resource</Th><Th>Status</Th><Th>Detected</Th><Th>Duration</Th><Th>Owner</Th></tr></thead>
            <tbody>{q.data.map((i) => (
              <tr key={i.id} className={cx('hover:bg-surface-2', i.parent_incident_id && 'text-ink-2')}>
                <Td className="tabular text-xs text-ink-3">INC-{i.number}</Td>
                <Td><SeverityBadge severity={i.severity} /></Td>
                <Td className="max-w-[460px]">
                  <Link href={`/incidents/${i.id}`} className="block truncate font-medium text-ink hover:text-accent">{i.title}</Link>
                  <div className="truncate text-xs text-ink-3">
                    {i.parent_incident_id ? 'Grouped under a related incident · ' : ''}{i.child_count ? `${i.child_count} related incidents · ` : ''}{i.trigger_summary}
                  </div>
                </Td>
                <Td className="text-xs">{i.resource_name ? <><div>{i.resource_name}</div><ProviderTag provider={i.provider} className="text-[11px]" /></> : i.account_name ?? 'multiple'}</Td>
                <Td><IncidentStatus status={i.status} /></Td>
                <Td className="whitespace-nowrap text-xs text-ink-2">{relTime(i.first_detected_at)}</Td>
                <Td className="tabular whitespace-nowrap text-xs">{duration(i.first_detected_at, i.resolved_at)}</Td>
                <Td className="text-xs text-ink-2">{i.assignee ?? '—'}</Td>
              </tr>
            ))}</tbody>
          </Table>
        )}
      </Card>
    </div>
  );
}
