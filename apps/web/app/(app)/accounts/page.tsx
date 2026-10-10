'use client';
import { useQuery } from '@tanstack/react-query';
import { Plus } from 'lucide-react';
import Link from 'next/link';
import { PageHeader } from '@/components/shell';
import { useCan } from '@/components/session';
import { ProviderTag, StateBadge } from '@/components/status';
import { Card, Empty, ErrorNote, Skeleton, Table, Td, Th } from '@/components/ui';
import { api } from '@/lib/api';
import { relTime } from '@/lib/format';
import { accountState } from '@/lib/state';

export default function Accounts() {
  const canManage = useCan('accounts.manage');
  const q = useQuery({ queryKey: ['accounts'], queryFn: () => api.get<any[]>('/accounts'), refetchInterval: 30_000 });
  return (
    <div className="mx-auto max-w-[1400px]">
      <PageHeader title="Cloud accounts" subtitle="Read-only integrations. Credentials are encrypted at rest and never displayed after submission."
        actions={canManage && <Link href="/accounts/new" className="inline-flex h-8 items-center gap-1.5 rounded-md bg-accent px-3 text-[13px] font-medium text-accent-ink hover:brightness-110"><Plus className="size-4" />Connect account</Link>} />
      <ErrorNote error={q.error} />
      <Card bodyClassName="p-0">
        {q.isLoading ? <Skeleton className="m-4 h-40" /> : !q.data?.length ? <Empty title="No cloud accounts">Connect Azure, DigitalOcean or Alibaba Cloud to discover resources.</Empty> : (
          <Table>
            <thead><tr><Th>Account</Th><Th>Provider</Th><Th>Status</Th><Th>Resources</Th><Th>Last success</Th><Th>Collection</Th><Th>Throttling</Th></tr></thead>
            <tbody>{q.data.map((a) => {
              const failing = (a.jobs ?? []).filter((j: any) => j.consecutive_failures > 0);
              return (
                <tr key={a.id} className="hover:bg-surface-2">
                  <Td><Link href={`/accounts/${a.id}`} className="font-medium hover:text-accent">{a.name}</Link><div className="text-xs text-ink-3">{a.credential_hint}</div></Td>
                  <Td><ProviderTag provider={a.provider} /></Td>
                  <Td><StateBadge size="sm" state={accountState(a.status)} title={a.status_reason ?? undefined} /> <span className="text-xs text-ink-3">{a.status}</span></Td>
                  <Td className="tabular">{a.resource_count}</Td>
                  <Td className="text-xs text-ink-2">{relTime(a.last_success_at)}</Td>
                  <Td className="text-xs">{failing.length ? <span className="text-critical-ink">{failing.map((j: any) => j.kind).join(', ')} failing</span> : <span className="text-ink-3">{(a.jobs ?? []).length} jobs ok</span>}</Td>
                  <Td className="text-xs text-ink-2">{a.throttle_events ? `${a.throttle_events} · last ${relTime(a.last_throttled_at)}` : 'none'}</Td>
                </tr>
              );
            })}</tbody>
          </Table>
        )}
      </Card>
    </div>
  );
}
