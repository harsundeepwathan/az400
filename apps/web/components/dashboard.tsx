'use client';
import { useQuery } from '@tanstack/react-query';
import { Cloud } from 'lucide-react';
import Link from 'next/link';
import { ProviderTag } from '@/components/status';
import { Empty } from '@/components/ui';
import { api } from '@/lib/api';
import { PROVIDER_LABEL, STATE_LABEL, STATE_ORDER, type OpState } from '@/lib/state';

export interface Summary {
  counts: { state: OpState; n: number }[];
  by_provider: { provider: string; state: OpState; n: number }[];
  incidents: { unacknowledged: number; acknowledged: number; critical_open: number };
  critical: any[];
  recent: any[];
  disks: any[];
  top_cpu: any[];
  top_memory: any[];
  services: { monitored: number; ok: number; failing: number };
  failing_services: any[];
  trend: { metric: string; t: string; avg: number; max: number; resources: number }[];
  timeline: { t: string; state: OpState; n: number }[];
  accounts: { id: string; name: string; provider: string; status: string; status_reason: string | null; last_success_at: string | null; auth_method: string }[];
}

export const STATE_COLOR: Record<OpState, string> = {
  healthy: '--good', warning: '--warning', critical: '--critical', down: '--critical-ink', stopped: '--axis',
  unknown: '--ink-3', maintenance: '--maint', no_data: '--surface-3',
};

export function useSummary() {
  return useQuery({ queryKey: ['summary'], queryFn: () => api.get<Summary>('/dashboard/summary'), refetchInterval: 30_000 });
}

export function ProviderHealth({ data }: { data: Summary['by_provider'] }) {
  const providers = [...new Set(data.map((d) => d.provider))];
  if (!providers.length) return <Empty title="No monitored resources yet" icon={<Cloud className="size-6" />}>Connect a cloud account or enroll an agent to start monitoring.</Empty>;
  return (
    <div className="space-y-3">
      {providers.map((p) => {
        const rows = STATE_ORDER.map((s) => ({ s, n: data.find((d) => d.provider === p && d.state === s)?.n ?? 0 })).filter((r) => r.n > 0);
        const total = rows.reduce((a, r) => a + r.n, 0);
        const bad = rows.filter((r) => ['down', 'critical', 'warning'].includes(r.s));
        return (
          <div key={p}>
            <div className="mb-1 flex items-center justify-between text-xs">
              <Link href={`/inventory?provider=${p}`} className="hover:underline"><ProviderTag provider={p} /></Link>
              <span className="text-ink-3">
                {bad.length ? bad.map((r) => `${r.n} ${STATE_LABEL[r.s].toLowerCase()}`).join(' · ') : 'all clear'} · {total} total
              </span>
            </div>
            <div className="flex h-2.5 gap-[2px] overflow-hidden rounded-full" role="img" aria-label={`${PROVIDER_LABEL[p] ?? p}: ${rows.map((r) => `${r.n} ${STATE_LABEL[r.s]}`).join(', ')}`}>
              {rows.map((r) => (
                <div key={r.s} title={`${STATE_LABEL[r.s]}: ${r.n}`} style={{ flexGrow: r.n, background: `var(${STATE_COLOR[r.s]})` }} />
              ))}
            </div>
          </div>
        );
      })}
      <StateLegend />
    </div>
  );
}

function StateLegend() {
  return (
    <div className="flex flex-wrap gap-x-3 gap-y-1 pt-1 text-[11px] text-ink-3">
      {(['healthy', 'warning', 'critical', 'down', 'unknown', 'no_data', 'maintenance', 'stopped'] as OpState[]).map((s) => (
        <span key={s} className="inline-flex items-center gap-1"><span className="size-2 rounded-[2px]" style={{ background: `var(${STATE_COLOR[s]})` }} />{STATE_LABEL[s]}</span>
      ))}
    </div>
  );
}

