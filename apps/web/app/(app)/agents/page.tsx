'use client';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Copy, KeyRound } from 'lucide-react';
import Link from 'next/link';
import { useState } from 'react';
import { PageHeader } from '@/components/shell';
import { useCan } from '@/components/session';
import { StateBadge } from '@/components/status';
import { Button, Card, Dialog, Empty, ErrorNote, Field, Input, Mono, Skeleton, Table, Td, Th, cx } from '@/components/ui';
import { api } from '@/lib/api';
import { dateTime, relTime } from '@/lib/format';

export default function Agents() {
  const can = useCan('agents.manage');
  const qc = useQueryClient();
  const agents = useQuery({ queryKey: ['agents'], queryFn: () => api.get<any[]>('/agents'), refetchInterval: 30_000 });
  const tokens = useQuery({ queryKey: ['tokens'], queryFn: () => api.get<any[]>('/agents/enrollment-tokens'), enabled: can });
  const revoke = useMutation({ mutationFn: (id: string) => api.post(`/agents/${id}/revoke`), onSuccess: () => qc.invalidateQueries({ queryKey: ['agents'] }) });
  const revokeToken = useMutation({ mutationFn: (id: string) => api.del(`/agents/enrollment-tokens/${id}`), onSuccess: () => qc.invalidateQueries({ queryKey: ['tokens'] }) });
  const [open, setOpen] = useState(false);
  return (
    <div className="mx-auto max-w-[1400px]">
      <PageHeader title="Monitoring agents" subtitle="Outbound-only agents for Windows Server and Linux: heartbeats, host metrics, per-volume disk, and service state. No remote command execution."
        actions={can && <Button variant="primary" onClick={() => setOpen(true)}><KeyRound className="size-4" />Create enrollment token</Button>} />
      <ErrorNote error={agents.error ?? revoke.error} />
      <Card bodyClassName="p-0">
        {agents.isLoading ? <Skeleton className="m-4 h-40" /> : !agents.data?.length ? <Empty title="No agents enrolled">Create an enrollment token and run the installer on a host.</Empty> : (
          <Table>
            <thead><tr><Th>Host</Th><Th>Resource state</Th><Th>OS</Th><Th>Version</Th><Th>Last heartbeat</Th><Th>Latency</Th><Th>Queue</Th><Th>Collector errors</Th><Th>Status</Th><Th /></tr></thead>
            <tbody>{agents.data.map((a) => {
              const stale = a.last_heartbeat_at && Date.now() - new Date(a.last_heartbeat_at).getTime() > 300_000;
              return (
                <tr key={a.id} className={cx(a.status !== 'active' && 'opacity-60')}>
                  <Td>{a.resource_id ? <Link href={`/resources/${a.resource_id}`} className="font-medium hover:text-accent">{a.hostname}</Link> : a.hostname}<div className="text-xs text-ink-3">{a.last_ip}</div></Td>
                  <Td>{a.operational_state && <StateBadge size="sm" state={a.operational_state} />}</Td>
                  <Td className="text-xs">{a.os_name} {a.os_version} <span className="text-ink-3">{a.arch}</span></Td>
                  <Td className="text-xs">{a.agent_version}</Td>
                  <Td className={cx('text-xs', stale ? 'text-critical-ink' : 'text-ink-2')}>{a.last_heartbeat_at ? relTime(a.last_heartbeat_at) : 'never'}</Td>
                  <Td className="tabular text-xs">{a.last_heartbeat_latency_ms != null ? `${a.last_heartbeat_latency_ms} ms` : '—'}</Td>
                  <Td className="tabular text-xs">{a.last_queue_depth ?? 0}{a.last_dropped_batches ? <span className="text-warning-ink"> · {a.last_dropped_batches} dropped</span> : null}</Td>
                  <Td className="max-w-[220px] truncate text-xs text-ink-2" title={JSON.stringify(a.collector_errors)}>{a.collector_errors?.length ? a.collector_errors.map((e: any) => e.collector).join(', ') : 'none'}</Td>
                  <Td className="text-xs">{a.status}</Td>
                  <Td>{can && a.status === 'active' && <Button size="sm" onClick={() => confirm(`Revoke agent on ${a.hostname}? It will stop being able to report.`) && revoke.mutate(a.id)}>Revoke</Button>}</Td>
                </tr>
              );
            })}</tbody>
          </Table>
        )}
      </Card>
      {can && (
        <Card title="Enrollment tokens" subtitle="Single- or limited-use, expiring. Only a hash is stored." className="mt-4" bodyClassName="p-0">
          <Table>
            <thead><tr><Th>Prefix</Th><Th>Description</Th><Th>Uses</Th><Th>Expires</Th><Th>Created by</Th><Th /></tr></thead>
            <tbody>{(tokens.data ?? []).map((t) => {
              const dead = t.revoked_at || new Date(t.expires_at) < new Date() || t.uses >= t.max_uses;
              return (
                <tr key={t.id} className={cx(dead && 'opacity-50')}><Td><Mono>{t.token_prefix}…</Mono></Td><Td className="text-xs">{t.description || '—'}</Td>
                  <Td className="tabular text-xs">{t.uses}/{t.max_uses}</Td><Td className="text-xs">{t.revoked_at ? 'revoked' : dateTime(t.expires_at)}</Td><Td className="text-xs">{t.created_by_name}</Td>
                  <Td>{!dead && <Button size="sm" onClick={() => revokeToken.mutate(t.id)}>Revoke</Button>}</Td></tr>
              );
            })}</tbody>
          </Table>
        </Card>
      )}
      {open && <TokenDialog onClose={() => setOpen(false)} />}
    </div>
  );
}

function TokenDialog({ onClose }: { onClose: () => void }) {
  const qc = useQueryClient();
  const [v, setV] = useState({ description: '', max_uses: 1, ttl_hours: 24 });
  const m = useMutation({ mutationFn: () => api.post<any>('/agents/enrollment-tokens', v), onSuccess: () => qc.invalidateQueries({ queryKey: ['tokens'] }) });
  const copy = (s: string) => navigator.clipboard?.writeText(s);
  return (
    <Dialog open onClose={onClose} title="Create enrollment token" width="max-w-2xl">
      {!m.data ? (
        <form className="space-y-3" onSubmit={(e) => { e.preventDefault(); m.mutate(); }}>
          <Field label="Description"><Input value={v.description} onChange={(e) => setV({ ...v, description: e.target.value })} placeholder="web tier rollout" /></Field>
          <div className="grid grid-cols-2 gap-3">
            <Field label="Maximum uses" hint="Use 1 per host, or more for fleet rollouts"><Input type="number" min={1} max={10000} value={v.max_uses} onChange={(e) => setV({ ...v, max_uses: Number(e.target.value) })} /></Field>
            <Field label="Valid for (hours)"><Input type="number" min={1} max={720} value={v.ttl_hours} onChange={(e) => setV({ ...v, ttl_hours: Number(e.target.value) })} /></Field>
          </div>
          <ErrorNote error={m.error} />
          <div className="flex justify-end"><Button type="submit" variant="primary" disabled={m.isPending}>Create token</Button></div>
        </form>
      ) : (
        <div className="space-y-3">
          <p className="text-[13px] text-warning-ink">Copy the token now. It will not be shown again.</p>
          <div className="flex items-center gap-2 rounded-md border border-border bg-surface-2 p-2"><Mono className="flex-1 break-all">{m.data.token}</Mono>
            <Button size="sm" onClick={() => copy(m.data.token)}><Copy className="size-3.5" />Copy</Button></div>
          {(['linux', 'windows'] as const).map((os) => (
            <div key={os}>
              <div className="mb-1 text-xs font-medium text-ink-2">{os === 'linux' ? 'Linux (Ubuntu, Debian, RHEL-compatible)' : 'Windows Server (PowerShell as Administrator)'}</div>
              <pre className="overflow-x-auto rounded-md border border-border bg-surface-2 p-2 font-mono text-[11px]">{m.data.install[os]}</pre>
            </div>
          ))}
          <p className="text-xs text-ink-3">Installers live in deploy/agent. See docs/AGENT.md for upgrade and uninstall.</p>
          <div className="flex justify-end"><Button onClick={onClose}>Done</Button></div>
        </div>
      )}
    </Dialog>
  );
}
