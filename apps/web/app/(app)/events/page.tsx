'use client';
import { useQuery } from '@tanstack/react-query';
import Link from 'next/link';
import { useState } from 'react';
import { PageHeader } from '@/components/shell';
import { TimeRangePicker, type Range } from '@/components/time-range';
import { Card, Empty, ErrorNote, Skeleton, Table, Td, Th, cx } from '@/components/ui';
import { api, qs } from '@/lib/api';
import { dateTime } from '@/lib/format';

export default function Events() {
  const [range, setRange] = useState<Range>({ range: '24h' });
  const q = useQuery({ queryKey: ['events', range], queryFn: () => api.get<any[]>('/events' + qs({ ...range, limit: 500 })), refetchInterval: 60_000 });
  return (
    <div className="mx-auto max-w-[1400px]">
      <PageHeader title="Change events" subtitle="Provider activity logs (Azure Activity Log, DigitalOcean actions) and agent-reported OS events — what changed, and when." />
      <div className="mb-3"><TimeRangePicker value={range} onChange={setRange} /></div>
      <ErrorNote error={q.error} />
      <Card bodyClassName="p-0">
        {q.isLoading ? <Skeleton className="m-4 h-40" /> : !q.data?.length ? <Empty title="No events in this range" /> : (
          <Table>
            <thead><tr><Th>Time</Th><Th>Resource</Th><Th>Source</Th><Th>Kind</Th><Th>Message</Th></tr></thead>
            <tbody>{q.data.map((e) => (
              <tr key={e.id}><Td className="whitespace-nowrap text-xs">{dateTime(e.at)}</Td>
                <Td className="text-xs">{e.resource_id ? <Link href={`/resources/${e.resource_id}?tab=events`} className="hover:underline">{e.resource_name}</Link> : '—'}</Td>
                <Td className="text-xs">{e.source}</Td><Td className="text-xs text-ink-2">{e.kind}</Td>
                <Td className={cx(e.severity === 'error' || e.severity === 'critical' ? 'text-critical-ink' : '')}>{e.message}</Td></tr>))}</tbody>
          </Table>
        )}
      </Card>
    </div>
  );
}
