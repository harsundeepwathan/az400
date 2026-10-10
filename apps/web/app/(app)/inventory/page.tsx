'use client';
import { useQuery } from '@tanstack/react-query';
import { Download, Search } from 'lucide-react';
import Link from 'next/link';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import { Suspense, useEffect, useState } from 'react';
import { PageHeader } from '@/components/shell';
import { Meter, ProviderTag, StateBadge } from '@/components/status';
import { Card, Empty, ErrorNote, Input, Select, Skeleton, Table, Td, Th, cx } from '@/components/ui';
import { api, qs } from '@/lib/api';
import { relTime } from '@/lib/format';
import { PROVIDER_LABEL, STATE_LABEL, STATE_ORDER, TYPE_LABEL } from '@/lib/state';

interface Row {
  id: string; name: string; provider: string; resource_type: string; region: string | null; environment: string | null;
  os_type: string | null; power_state: string; operational_state: string; state_reason: string | null; account_name: string | null;
  cpu: number | null; mem: number | null; disk_max: number | null; last_heartbeat: string | null; has_agent: boolean; flapping: boolean;
  metric_gaps: Record<string, string>; monitoring_enabled: boolean; tags: Record<string, string>;
}

const FILTERS = ['q', 'provider', 'type', 'region', 'environment', 'state', 'tag', 'sort', 'monitored'] as const;

function Inventory() {
  const params = useSearchParams();
  const router = useRouter();
  const path = usePathname();
  const f = Object.fromEntries(FILTERS.map((k) => [k, params.get(k) ?? ''])) as Record<(typeof FILTERS)[number], string>;
  const [search, setSearch] = useState(f.q);
  const set = (k: string, v: string) => {
    const n = new URLSearchParams(params.toString());
    if (v) n.set(k, v); else n.delete(k);
    router.replace(`${path}?${n.toString()}`, { scroll: false });
  };
  useEffect(() => {
    const t = setTimeout(() => search !== f.q && set('q', search), 250);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search]);

  const q = useQuery({
    queryKey: ['resources', f],
    queryFn: () => api.get<{ items: Row[]; facets: { providers: string[]; types: string[]; regions: string[] | null; environments: string[] | null } }>(
      '/resources' + qs({ ...f, monitored: f.monitored || 'true', sort: f.sort || 'severity' })),
    refetchInterval: 30_000,
    placeholderData: (prev) => prev,
  });
  const facets = q.data?.facets;

  return (
    <div className="mx-auto max-w-[1600px]">
      <PageHeader title="Infrastructure inventory" subtitle="Every discovered resource and agent-monitored host, normalized across providers"
        actions={<a href="/api/v1/reports/inventory?format=csv" className="inline-flex h-8 items-center gap-1.5 rounded-md border border-border-strong bg-surface px-3 text-[13px] hover:bg-surface-2"><Download className="size-3.5" />Export CSV</a>} />
      <div className="mb-3 flex flex-wrap items-center gap-2" role="search">
        <div className="relative w-64">
          <Search className="pointer-events-none absolute left-2.5 top-2 size-4 text-ink-3" aria-hidden />
          <Input aria-label="Search resources" placeholder="Search name or resource ID" value={search} onChange={(e) => setSearch(e.target.value)} className="pl-8" />
        </div>
        <Select aria-label="Provider" value={f.provider} onChange={(e) => set('provider', e.target.value)}>
          <option value="">All providers</option>
          {facets?.providers?.map((p) => <option key={p} value={p}>{PROVIDER_LABEL[p] ?? p}</option>)}
        </Select>
        <Select aria-label="Resource type" value={f.type} onChange={(e) => set('type', e.target.value)}>
          <option value="">All types</option>
          {facets?.types?.map((t) => <option key={t} value={t}>{TYPE_LABEL[t] ?? t}</option>)}
        </Select>
        <Select aria-label="Region" value={f.region} onChange={(e) => set('region', e.target.value)}>
          <option value="">All regions</option>
          {facets?.regions?.map((r) => <option key={r} value={r}>{r}</option>)}
        </Select>
        <Select aria-label="Environment" value={f.environment} onChange={(e) => set('environment', e.target.value)}>
          <option value="">All environments</option>
          {facets?.environments?.map((r) => <option key={r} value={r}>{r}</option>)}
        </Select>
        <Select aria-label="State" value={f.state} onChange={(e) => set('state', e.target.value)}>
          <option value="">All states</option>
          <option value="down,critical,warning">Needs attention</option>
          {STATE_ORDER.map((s) => <option key={s} value={s}>{STATE_LABEL[s]}</option>)}
        </Select>
        <Input aria-label="Tag filter" placeholder="tag key or key:value" defaultValue={f.tag} className="w-44"
          onKeyDown={(e) => e.key === 'Enter' && set('tag', (e.target as HTMLInputElement).value)} onBlur={(e) => set('tag', e.target.value)} />
        <Select aria-label="Sort" value={f.sort || 'severity'} onChange={(e) => set('sort', e.target.value)}>
          <option value="severity">Sort: severity</option>
          <option value="name">Sort: name</option>
          <option value="cpu">Sort: CPU</option>
          <option value="memory">Sort: memory</option>
          <option value="disk">Sort: disk</option>
          <option value="heartbeat">Sort: oldest heartbeat</option>
        </Select>
        <Select aria-label="Monitoring" value={f.monitored || 'true'} onChange={(e) => set('monitored', e.target.value)}>
          <option value="true">Monitored</option>
          <option value="false">Not monitored</option>
          <option value="all">All</option>
        </Select>
        {FILTERS.some((k) => k !== 'sort' && f[k]) && <button className="text-xs text-accent hover:underline" onClick={() => { setSearch(''); router.replace(path); }}>Clear filters</button>}
      </div>
      <ErrorNote error={q.error} />
      <Card bodyClassName="p-0">
        {q.isLoading ? <Skeleton className="m-4 h-64" /> : !q.data?.items.length ? (
          <Empty title="No resources match">Adjust the filters, connect a cloud account, or enroll an agent.</Empty>
        ) : (
          <Table className="max-h-[calc(100vh-230px)]">
            <thead>
              <tr>
                <Th>Resource</Th><Th>Provider · region</Th><Th>Type · environment</Th><Th>Health</Th><Th>Power</Th>
                <Th className="w-24">CPU</Th><Th className="w-24">Memory</Th><Th className="w-24">Disk (max)</Th><Th>Heartbeat</Th>
              </tr>
            </thead>
            <tbody>
              {q.data.items.map((r) => (
                <tr key={r.id} className={cx('hover:bg-surface-2', !r.monitoring_enabled && 'opacity-60')}>
                  <Td className="max-w-[240px]">
                    <Link href={`/resources/${r.id}`} className="block truncate font-medium text-ink hover:text-accent">{r.name}</Link>
                    <div className="truncate text-[11px] text-ink-3" title={r.state_reason ?? ''}>{r.state_reason}</div>
                  </Td>
                  <Td className="whitespace-nowrap"><ProviderTag provider={r.provider} /><div className="text-[11px] text-ink-3">{r.region ?? 'no region'}</div></Td>
                  <Td className="whitespace-nowrap text-ink-2">{TYPE_LABEL[r.resource_type] ?? r.resource_type}{r.os_type ? <span className="text-ink-3"> · {r.os_type}</span> : null}
                    <div className="text-[11px] text-ink-3">{r.environment ?? '—'}</div></Td>
                  <Td><StateBadge state={r.operational_state} size="sm" />{r.flapping && <span className="ml-1 text-[11px] text-warning-ink">flapping</span>}</Td>
                  <Td className="whitespace-nowrap text-xs text-ink-2">{r.power_state.replace('_', ' ')}</Td>
                  <Td><Metric v={r.cpu} gap={r.metric_gaps?.['cpu.utilization']} warn={85} crit={95} /></Td>
                  <Td><Metric v={r.mem} gap={r.metric_gaps?.['memory.utilization']} warn={85} crit={95} /></Td>
                  <Td><Metric v={r.disk_max} gap={r.metric_gaps?.['disk.utilization']} warn={80} crit={90} /></Td>
                  <Td className="whitespace-nowrap text-xs">
                    {r.last_heartbeat ? <span className={cx(Date.now() - new Date(r.last_heartbeat).getTime() > 300_000 ? 'text-critical-ink' : 'text-ink-2')}>{relTime(r.last_heartbeat)}</span>
                      : <span className="text-ink-3">{r.has_agent ? 'never' : 'no agent'}</span>}
                  </Td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>
      {q.data && <p className="mt-2 text-xs text-ink-3">{q.data.items.length} resources</p>}
    </div>
  );
}

function Metric({ v, gap, warn, crit }: { v: number | null; gap?: string; warn: number; crit: number }) {
  if (v == null && gap) return <span className="text-[11px] text-ink-3" title={gap}>unavailable</span>;
  return <Meter value={v} warn={warn} crit={crit} />;
}

export default function Page() {
  return <Suspense><Inventory /></Suspense>;
}
