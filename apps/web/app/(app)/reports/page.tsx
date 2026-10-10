'use client';
import { useQuery } from '@tanstack/react-query';
import { Download } from 'lucide-react';
import { useSearchParams } from 'next/navigation';
import { Suspense, useState } from 'react';
import { PageHeader } from '@/components/shell';
import { TimeRangePicker, type Range } from '@/components/time-range';
import { Card, ErrorNote, Skeleton, Table, Tabs, Td, Th } from '@/components/ui';
import { qs } from '@/lib/api';

const REPORTS = {
  availability: { label: 'Availability', range: '30d' as const },
  incidents: { label: 'Incidents', range: '30d' as const },
  utilization: { label: 'Utilization', range: '7d' as const },
  disk: { label: 'Disk capacity', range: undefined },
  services: { label: 'Service failures', range: '30d' as const },
  inventory: { label: 'Inventory', range: undefined },
};
type Key = keyof typeof REPORTS;
const path = (k: Key) => `/api/v1/reports/${k === 'disk' ? 'disk-capacity' : k}`;

function Reports() {
  const params = useSearchParams();
  const [tab, setTab] = useState<Key>((params.get('tab') as Key) ?? 'availability');
  const [range, setRange] = useState<Range>({ range: REPORTS[tab].range ?? '30d' });
  const [strict, setStrict] = useState(false);
  const extra = tab === 'availability' && strict ? { critical_is_down: 'true' } : {};
  const query = qs({ ...(REPORTS[tab].range ? range : {}), ...extra });
  const q = useQuery({
    queryKey: ['report', tab, query],
    queryFn: async () => {
      const res = await fetch(path(tab) + query, { credentials: 'same-origin' });
      if (!res.ok) throw new Error((await res.json()).message);
      return res.json() as Promise<{ title: string; notes: string[]; data: any }>;
    },
  });
  const rows: any[] = Array.isArray(q.data?.data) ? q.data!.data : q.data?.data?.resources ?? q.data?.data?.incidents ?? [];
  const cols = rows.length ? Object.keys(rows[0]).filter((k) => !['id', 'resource_id'].includes(k)).slice(0, 10) : [];
  const fmt = (v: unknown) => v == null ? '—' : typeof v === 'number' ? (Number.isInteger(v) ? v : v.toFixed(2)) : typeof v === 'boolean' ? (v ? 'yes' : 'no') : String(v);
  return (
    <div className="mx-auto max-w-[1500px]">
      <PageHeader title="Reports" subtitle="Every figure states its calculation method. Exports carry the same methodology notes."
        actions={<>
          <a className="inline-flex h-8 items-center gap-1.5 rounded-md border border-border-strong bg-surface px-3 text-[13px] hover:bg-surface-2" href={path(tab) + qs({ ...(REPORTS[tab].range ? range : {}), ...extra, format: 'csv' })}><Download className="size-3.5" />CSV</a>
          <a className="inline-flex h-8 items-center gap-1.5 rounded-md border border-border-strong bg-surface px-3 text-[13px] hover:bg-surface-2" href={path(tab) + qs({ ...(REPORTS[tab].range ? range : {}), ...extra, format: 'pdf' })}><Download className="size-3.5" />PDF</a>
        </>} />
      <div className="mb-3 flex flex-wrap items-center gap-3">
        <Tabs value={tab} onChange={(t) => { setTab(t); setRange({ range: REPORTS[t].range ?? '30d' }); }} items={Object.entries(REPORTS).map(([k, v]) => ({ value: k as Key, label: v.label }))} />
        {REPORTS[tab].range && <TimeRangePicker value={range} onChange={setRange} />}
        {tab === 'availability' && <label className="flex items-center gap-1.5 text-xs"><input type="checkbox" checked={strict} onChange={(e) => setStrict(e.target.checked)} />Count Critical as unavailable</label>}
      </div>
      <ErrorNote error={q.error} />
      {q.data && (
        <Card title={q.data.title} className="mb-4">
          <ul className="space-y-1 text-xs text-ink-2">{q.data.notes.map((n) => <li key={n}>{n}</li>)}</ul>
        </Card>
      )}
      <Card bodyClassName="p-0">
        {q.isLoading ? <Skeleton className="m-4 h-64" /> : (
          <Table className="max-h-[60vh]">
            <thead><tr>{cols.map((c) => <Th key={c}>{c.replace(/_/g, ' ')}</Th>)}</tr></thead>
            <tbody>{rows.map((r, i) => <tr key={i}>{cols.map((c) => <Td key={c} className="whitespace-nowrap text-xs">{fmt(r[c])}</Td>)}</tr>)}</tbody>
          </Table>
        )}
      </Card>
    </div>
  );
}

export default function Page() { return <Suspense><Reports /></Suspense>; }
