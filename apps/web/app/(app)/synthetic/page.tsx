'use client';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Plus } from 'lucide-react';
import { useState } from 'react';
import { PageHeader } from '@/components/shell';
import { useCan } from '@/components/session';
import { Button, Card, Dialog, Empty, ErrorNote, Field, Input, Select, Skeleton, Table, Td, Th, cx } from '@/components/ui';
import { api } from '@/lib/api';
import { relTime } from '@/lib/format';

export default function Synthetic() {
  const can = useCan('monitoring.configure');
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['synthetic'], queryFn: () => api.get<any[]>('/synthetic-checks'), refetchInterval: 30_000 });
  const del = useMutation({ mutationFn: (id: string) => api.del(`/synthetic-checks/${id}`), onSuccess: () => qc.invalidateQueries({ queryKey: ['synthetic'] }) });
  const [edit, setEdit] = useState<any | null>(null);
  return (
    <div className="mx-auto max-w-[1400px]">
      <PageHeader title="Synthetic checks" subtitle="HTTP(S), TCP, DNS, TLS-expiry and ICMP probes. Public probes cannot reach private networks; deploy a private probe for internal endpoints."
        actions={can && <Button variant="primary" onClick={() => setEdit({ kind: 'http', interval_seconds: 60, probe_scope: 'public', enabled: true, counts_for_liveness: false, config: {} })}><Plus className="size-4" />New check</Button>} />
      <ErrorNote error={q.error ?? del.error} />
      <Card bodyClassName="p-0">
        {q.isLoading ? <Skeleton className="m-4 h-40" /> : !q.data?.length ? <Empty title="No synthetic checks" /> : (
          <Table>
            <thead><tr><Th>Check</Th><Th>Type</Th><Th>Target</Th><Th>Probe</Th><Th>Last result</Th><Th>Latency</Th><Th>Success 24h</Th><Th>Last run</Th><Th /></tr></thead>
            <tbody>{q.data.map((c) => (
              <tr key={c.id} className={cx(!c.enabled && 'opacity-60')}>
                <Td><div className="font-medium">{c.name}</div>{c.resource_name && <div className="text-xs text-ink-3">linked to {c.resource_name}{c.counts_for_liveness ? ' · liveness' : ''}</div>}</Td>
                <Td className="text-xs uppercase">{c.kind}</Td>
                <Td className="max-w-[260px] truncate font-mono text-[12px]" title={c.target}>{c.target}</Td>
                <Td className="text-xs">{c.probe_scope} · {c.locations.join(', ')}</Td>
                <Td>{c.last_ok == null ? <span className="text-xs text-ink-3">pending</span> : c.last_ok
                  ? <span className="text-xs font-medium text-good-ink">● passing</span>
                  : <span className="text-xs font-medium text-critical-ink" title={c.last_error}>● failing ×{c.consecutive_failures}<div className="max-w-[240px] truncate font-normal">{c.last_error}</div></span>}</Td>
                <Td className="tabular text-xs">{c.last_latency_ms != null ? `${c.last_latency_ms} ms` : '—'}</Td>
                <Td className="tabular text-xs">{c.success_24h != null ? `${c.success_24h}%` : '—'}</Td>
                <Td className="text-xs text-ink-2">{relTime(c.last_run_at)}</Td>
                <Td className="space-x-1 whitespace-nowrap text-right">{can && <><Button size="sm" onClick={() => setEdit(c)}>Edit</Button>
                  <Button size="sm" variant="ghost" onClick={() => confirm('Delete check?') && del.mutate(c.id)}>Delete</Button></>}</Td>
              </tr>))}</tbody>
          </Table>
        )}
      </Card>
      {edit && <CheckDialog check={edit} onClose={() => setEdit(null)} />}
    </div>
  );
}

function CheckDialog({ check, onClose }: { check: any; onClose: () => void }) {
  const qc = useQueryClient();
  const [c, setC] = useState<any>({ ...check, config: { ...check.config } });
  const resources = useQuery({ queryKey: ['resources-min'], queryFn: () => api.get<any>('/resources?limit=2000&sort=name') });
  const set = (k: string, v: unknown) => setC((x: any) => ({ ...x, [k]: v }));
  const cfg = (k: string, v: unknown) => setC((x: any) => ({ ...x, config: { ...x.config, [k]: v === '' ? undefined : v } }));
  const m = useMutation({
    mutationFn: () => {
      const body = { name: c.name, kind: c.kind, target: c.target, interval_seconds: Number(c.interval_seconds), probe_scope: c.probe_scope,
        locations: c.locations ?? ['default'], enabled: c.enabled, resource_id: c.resource_id || null, counts_for_liveness: !!c.counts_for_liveness, config: c.config };
      return c.id ? api.put(`/synthetic-checks/${c.id}`, body) : api.post('/synthetic-checks', body);
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['synthetic'] }); onClose(); },
  });
  const ph: Record<string, string> = { http: 'https://example.com/health', tcp: 'db.example.com:5432', dns: 'example.com', tls: 'example.com:443', icmp: 'gateway.example.com' };
  return (
    <Dialog open onClose={onClose} title={c.id ? 'Edit synthetic check' : 'New synthetic check'} width="max-w-xl">
      <form className="space-y-3" onSubmit={(e) => { e.preventDefault(); m.mutate(); }}>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Name"><Input required value={c.name ?? ''} onChange={(e) => set('name', e.target.value)} /></Field>
          <Field label="Type"><Select value={c.kind} onChange={(e) => set('kind', e.target.value)} className="w-full">
            <option value="http">HTTP / HTTPS</option><option value="tcp">TCP port</option><option value="dns">DNS</option><option value="tls">TLS certificate</option><option value="icmp">ICMP ping</option></Select></Field>
        </div>
        <Field label="Target"><Input required value={c.target ?? ''} onChange={(e) => set('target', e.target.value)} placeholder={ph[c.kind]} className="font-mono" /></Field>
        {c.kind === 'http' && (
          <div className="grid grid-cols-2 gap-3">
            <Field label="Expected status codes" hint="Comma separated; default 2xx/3xx"><Input value={(c.config.expected_status ?? []).join(', ')} onChange={(e) => cfg('expected_status', e.target.value.split(',').map((x) => Number(x.trim())).filter(Boolean))} /></Field>
            <Field label="Body must contain"><Input value={c.config.body_contains ?? ''} onChange={(e) => cfg('body_contains', e.target.value)} /></Field>
          </div>
        )}
        {c.kind === 'dns' && (
          <div className="grid grid-cols-2 gap-3">
            <Field label="Record type"><Select value={c.config.record_type ?? 'A'} onChange={(e) => cfg('record_type', e.target.value)} className="w-full">{['A', 'AAAA', 'CNAME', 'MX', 'TXT'].map((x) => <option key={x}>{x}</option>)}</Select></Field>
            <Field label="Expected values" hint="Comma separated, optional"><Input value={(c.config.expected_values ?? []).join(', ')} onChange={(e) => cfg('expected_values', e.target.value.split(',').map((x) => x.trim()).filter(Boolean))} /></Field>
          </div>
        )}
        {c.kind === 'tls' && <Field label="Warn when expiring within (days)"><Input type="number" min={1} value={c.config.warn_days ?? 14} onChange={(e) => cfg('warn_days', Number(e.target.value))} /></Field>}
        <div className="grid grid-cols-3 gap-3">
          <Field label="Interval (s)"><Input type="number" min={30} value={c.interval_seconds} onChange={(e) => set('interval_seconds', e.target.value)} /></Field>
          <Field label="Probe"><Select value={c.probe_scope} onChange={(e) => set('probe_scope', e.target.value)} className="w-full"><option value="public">Public</option><option value="private">Private</option></Select></Field>
          <Field label="Timeout (s)"><Input type="number" min={1} max={60} value={c.config.timeout_seconds ?? 10} onChange={(e) => cfg('timeout_seconds', Number(e.target.value))} /></Field>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Linked resource (optional)">
            <Select value={c.resource_id ?? ''} onChange={(e) => set('resource_id', e.target.value)} className="w-full">
              <option value="">None</option>{resources.data?.items.map((r: any) => <option key={r.id} value={r.id}>{r.name}</option>)}
            </Select>
          </Field>
          <label className="flex items-center gap-2 pt-5 text-xs"><input type="checkbox" checked={!!c.counts_for_liveness} onChange={(e) => set('counts_for_liveness', e.target.checked)} disabled={!c.resource_id} />
            Counts as an independent liveness signal for the resource</label>
        </div>
        <ErrorNote error={m.error} />
        <div className="flex justify-end"><Button type="submit" variant="primary" disabled={m.isPending}>Save check</Button></div>
      </form>
    </Dialog>
  );
}
