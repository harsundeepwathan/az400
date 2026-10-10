'use client';
// Large-screen NOC view. Fixed grid areas and capped list lengths keep the layout
// stable between refreshes, so nothing jumps while people are reading from across a room.
import { useQuery } from '@tanstack/react-query';
import { AlertOctagon, CheckCircle2, Radar } from 'lucide-react';
import { useRouter } from 'next/navigation';
import { useEffect, useState } from 'react';
import { ProviderHealth, useSummary } from '@/components/dashboard';
import { SessionProvider, useMeQuery } from '@/components/session';
import { IncidentStatus, StateBadge } from '@/components/status';
import { cx } from '@/components/ui';
import { api } from '@/lib/api';
import { duration, relTime } from '@/lib/format';

export default function Wallboard() {
  const me = useMeQuery();
  const router = useRouter();
  useEffect(() => { if (me.isError) router.replace('/login?next=/wallboard'); }, [me.isError, router]);
  if (!me.data) return null;
  return <SessionProvider me={me.data}><Board org={me.data.active_org?.name ?? ''} demo={!!me.data.active_org?.is_demo} /></SessionProvider>;
}

function Clock() {
  const [now, setNow] = useState<Date | null>(null);
  useEffect(() => { setNow(new Date()); const t = setInterval(() => setNow(new Date()), 1000); return () => clearInterval(t); }, []);
  return <span className="tabular">{now?.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</span>;
}

function Board({ org, demo }: { org: string; demo: boolean }) {
  const s = useSummary();
  const unhealthy = useQuery({
    queryKey: ['wall-unhealthy'],
    queryFn: () => api.get<{ items: any[] }>('/resources?state=down,critical,warning,unknown&limit=14'),
    refetchInterval: 15_000,
  });
  const d = s.data;
  const n = (st: string[]) => d?.counts.filter((c) => st.includes(c.state)).reduce((a, c) => a + c.n, 0) ?? 0;
  const total = d?.counts.reduce((a, c) => a + c.n, 0) ?? 0;
  const stale = s.dataUpdatedAt && Date.now() - s.dataUpdatedAt > 90_000;
  return (
    <div className="flex h-screen flex-col gap-4 overflow-hidden p-6 text-[15px]">
      <header className="flex items-center gap-3">
        <Radar className="size-7 text-accent" aria-hidden />
        <h1 className="text-2xl font-semibold tracking-tight">{org}</h1>
        {demo && <span className="rounded bg-warning-soft px-2 py-0.5 text-sm text-warning-ink">Demo — synthetic data</span>}
        <div className="flex-1" />
        {stale ? <span className="text-sm text-critical-ink">Data is stale — last update {relTime(new Date(s.dataUpdatedAt))}</span>
          : <span className="text-sm text-ink-3">Live · refreshes every 30s</span>}
        <span className="text-2xl font-medium"><Clock /></span>
      </header>

      <div className="grid grid-cols-6 gap-4">
        {[['Monitored', total, ''], ['Healthy', n(['healthy']), 'text-good-ink'], ['Warning', n(['warning']), 'text-warning-ink'],
          ['Critical', n(['critical']), 'text-critical-ink'], ['Down', n(['down']), 'text-critical-ink'], ['Unacknowledged', d?.incidents.unacknowledged ?? 0, 'text-critical-ink']]
          .map(([label, value, cls]) => (
            <div key={label as string} className="rounded-xl border border-border bg-surface px-5 py-4">
              <div className="text-sm text-ink-3">{label}</div>
              <div className={cx('tabular mt-1 text-5xl font-semibold tracking-tight', (value as number) > 0 ? cls : 'text-ink')}>{value as number}</div>
            </div>
          ))}
      </div>

      <div className="grid min-h-0 flex-1 grid-cols-3 gap-4">
        <section className="col-span-2 flex min-h-0 flex-col rounded-xl border border-border bg-surface">
          <h2 className="border-b border-border px-5 py-3 text-base font-semibold">Active incidents</h2>
          <ul className="min-h-0 flex-1 divide-y divide-border overflow-hidden">
            {(d?.critical ?? []).slice(0, 8).map((i) => (
              <li key={i.id} className="flex items-center gap-4 px-5 py-3">
                <AlertOctagon className={cx('size-6 shrink-0', i.severity === 'critical' ? 'text-critical' : 'text-warning')} aria-label={i.severity} />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-lg font-medium">{i.title}</div>
                  <div className="truncate text-sm text-ink-3">{i.resource_name ?? 'multiple resources'} {i.region ? `· ${i.region}` : ''}</div>
                </div>
                <IncidentStatus status={i.status} />
                <span className="tabular w-24 text-right text-lg">{duration(i.first_detected_at)}</span>
              </li>
            ))}
            {d && d.critical.length === 0 && (
              <li className="flex h-full flex-col items-center justify-center gap-2 py-16 text-ink-3"><CheckCircle2 className="size-12 text-good" />No active incidents</li>
            )}
          </ul>
        </section>

        <section className="flex min-h-0 flex-col gap-4">
          <div className="rounded-xl border border-border bg-surface p-5">
            <h2 className="mb-3 text-base font-semibold">Providers</h2>
            {d && <ProviderHealth data={d.by_provider} />}
          </div>
          <div className="min-h-0 flex-1 overflow-hidden rounded-xl border border-border bg-surface">
            <h2 className="border-b border-border px-5 py-3 text-base font-semibold">Service outages</h2>
            <ul className="divide-y divide-border">
              {(d?.failing_services ?? []).slice(0, 6).map((x) => (
                <li key={x.id} className="flex items-center gap-2 px-5 py-2.5"><span className="size-2.5 rounded-full bg-critical" aria-hidden />
                  <span className="min-w-0 flex-1 truncate">{x.display_name ?? x.name} <span className="text-ink-3">· {x.resource_name}</span></span>
                  <span className="text-sm text-critical-ink">{x.current_state}</span></li>
              ))}
              {d && d.failing_services.length === 0 && <li className="px-5 py-4 text-ink-3">All required services running</li>}
            </ul>
          </div>
        </section>

        <section className="col-span-2 min-h-0 overflow-hidden rounded-xl border border-border bg-surface">
          <h2 className="border-b border-border px-5 py-3 text-base font-semibold">Unhealthy hosts</h2>
          <div className="grid grid-cols-2 divide-x divide-border">
            {[0, 1].map((col) => (
              <ul key={col} className="divide-y divide-border">
                {(unhealthy.data?.items ?? []).slice(col * 7, col * 7 + 7).map((r) => (
                  <li key={r.id} className="flex items-center gap-3 px-5 py-2.5">
                    <StateBadge state={r.operational_state} />
                    <div className="min-w-0 flex-1"><div className="truncate font-medium">{r.name}</div><div className="truncate text-xs text-ink-3">{r.state_reason}</div></div>
                  </li>
                ))}
              </ul>
            ))}
          </div>
        </section>

        <section className="min-h-0 overflow-hidden rounded-xl border border-border bg-surface">
          <h2 className="border-b border-border px-5 py-3 text-base font-semibold">Recent incidents</h2>
          <ol className="divide-y divide-border">
            {(d?.recent ?? []).slice(0, 7).map((i) => (
              <li key={i.id} className="flex items-center gap-3 px-5 py-2.5">
                <span className="tabular w-20 text-sm text-ink-3">{new Date(i.first_detected_at).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}</span>
                <span className="min-w-0 flex-1 truncate">{i.title}</span><IncidentStatus status={i.status} />
              </li>
            ))}
          </ol>
        </section>
      </div>
    </div>
  );
}
