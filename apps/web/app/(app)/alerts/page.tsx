'use client';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Plus } from 'lucide-react';
import { useState } from 'react';
import { PageHeader } from '@/components/shell';
import { useCan } from '@/components/session';
import { SeverityBadge } from '@/components/status';
import { Button, Card, Dialog, ErrorNote, Field, Input, Select, Skeleton, Table, Td, Th, Textarea, cx } from '@/components/ui';
import { api } from '@/lib/api';
import { metricLabel } from '@/lib/format';

const METRICS = ['cpu.utilization', 'memory.utilization', 'disk.utilization', 'memory.swap_utilization', 'cpu.load1', 'cpu.iowait', 'net.in_bytes_per_sec',
  'net.out_bytes_per_sec', 'net.errors_per_sec', 'db.cpu_utilization', 'db.storage_utilization', 'app.http_5xx', 'app.response_time_ms', 'lb.data_path_availability',
  'storage.availability', 'tls.days_to_expiry', 'synthetic.latency_ms', 'agent.queue_depth'];

const KIND_LABEL: Record<string, string> = {
  metric_threshold: 'Metric threshold', heartbeat: 'Missing heartbeat', service_state: 'Required service state', synthetic: 'Synthetic check', provider_state: 'Provider health',
};

function describe(r: any) {
  switch (r.kind) {
    case 'metric_threshold': return `${metricLabel(r.metric)}${r.series_match ? ` (${r.series_match})` : ''} ${r.aggregation} ${r.operator} ${r.threshold}` +
      (r.recovery_threshold != null ? `, clears ${r.operator.startsWith('>') ? '<' : '>'} ${r.recovery_threshold}` : '') + (r.for_seconds ? ` for ${r.for_seconds / 60} min` : '');
    case 'heartbeat': return `No heartbeat for ${r.threshold / 60} min`;
    case 'service_state': return 'A required service is not in its expected state';
    case 'synthetic': return `${r.consecutive} consecutive check failures`;
    default: return 'Provider health reports unavailable';
  }
}

export default function AlertRules() {
  const can = useCan('monitoring.configure');
  const q = useQuery({ queryKey: ['rules'], queryFn: () => api.get<any[]>('/alert-rules') });
  const [edit, setEdit] = useState<any | null>(null);
  return (
    <div className="mx-auto max-w-[1300px]">
      <PageHeader title="Alert rules" subtitle="Initial policies are starting points: tune thresholds, evaluation windows, hysteresis and exclusions per OS, volume, environment or tag."
        actions={can && <Button variant="primary" onClick={() => setEdit({ kind: 'metric_threshold', severity: 'warning', aggregation: 'avg', operator: '>', for_seconds: 300, consecutive: 1, enabled: true, scope: {}, exclusions: {} })}><Plus className="size-4" />New rule</Button>} />
      <ErrorNote error={q.error} />
      <Card bodyClassName="p-0">
        {q.isLoading ? <Skeleton className="m-4 h-48" /> : (
          <Table>
            <thead><tr><Th>Rule</Th><Th>Type</Th><Th>Condition</Th><Th>Severity</Th><Th>Scope</Th><Th>Firing</Th><Th>Enabled</Th></tr></thead>
            <tbody>{q.data?.map((r) => (
              <tr key={r.id} className={cx('hover:bg-surface-2', can && 'cursor-pointer', !r.enabled && 'opacity-60')} onClick={() => can && setEdit(r)}>
                <Td><div className="font-medium">{r.name}</div><div className="text-xs text-ink-3">{r.description}</div></Td>
                <Td className="text-xs">{KIND_LABEL[r.kind]}</Td>
                <Td className="text-xs">{describe(r)}</Td>
                <Td><SeverityBadge severity={r.severity} /></Td>
                <Td className="max-w-[220px] truncate text-xs text-ink-2">{Object.keys(r.scope ?? {}).length ? JSON.stringify(r.scope) : 'all resources'}{Object.keys(r.exclusions ?? {}).length ? ' · with exclusions' : ''}</Td>
                <Td className={cx('tabular', r.firing ? 'font-semibold text-critical-ink' : 'text-ink-3')}>{r.firing}</Td>
                <Td className="text-xs">{r.enabled ? 'yes' : 'no'}</Td>
              </tr>))}</tbody>
          </Table>
        )}
      </Card>
      {edit && <RuleEditor rule={edit} onClose={() => setEdit(null)} />}
    </div>
  );
}

const csv = (s: string) => s.split(',').map((x) => x.trim()).filter(Boolean);

function RuleEditor({ rule, onClose }: { rule: any; onClose: () => void }) {
  const qc = useQueryClient();
  const [r, setR] = useState<any>({ ...rule });
  const [scope, setScope] = useState({
    providers: (rule.scope?.providers ?? []).join(', '), environments: (rule.scope?.environments ?? []).join(', '), os_types: (rule.scope?.os_types ?? []).join(', '),
    resource_types: (rule.scope?.resource_types ?? []).join(', '), excl_series: (rule.exclusions?.series ?? []).join(', '), excl_env: (rule.exclusions?.environments ?? []).join(', '),
  });
  const set = (k: string, v: unknown) => setR((x: any) => ({ ...x, [k]: v }));
  const save = useMutation({
    mutationFn: () => {
      const num = (v: unknown) => (v === '' || v == null ? null : Number(v));
      const body = {
        name: r.name, description: r.description ?? '', enabled: r.enabled, kind: r.kind, severity: r.severity,
        metric: r.kind === 'metric_threshold' ? r.metric : null, series_match: r.kind === 'metric_threshold' ? r.series_match || null : null,
        aggregation: r.aggregation, operator: r.kind === 'metric_threshold' ? r.operator : null, threshold: num(r.threshold), recovery_threshold: num(r.recovery_threshold),
        for_seconds: Number(r.for_seconds ?? 0), consecutive: Number(r.consecutive ?? 1),
        scope: Object.fromEntries(Object.entries({ providers: csv(scope.providers), environments: csv(scope.environments), os_types: csv(scope.os_types), resource_types: csv(scope.resource_types) }).filter(([, v]) => v.length)),
        exclusions: Object.fromEntries(Object.entries({ series: csv(scope.excl_series), environments: csv(scope.excl_env) }).filter(([, v]) => v.length)),
      };
      return r.id ? api.put(`/alert-rules/${r.id}`, body) : api.post('/alert-rules', body);
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['rules'] }); onClose(); },
  });
  const del = useMutation({ mutationFn: () => api.del(`/alert-rules/${r.id}`), onSuccess: () => { qc.invalidateQueries({ queryKey: ['rules'] }); onClose(); } });
  return (
    <Dialog open onClose={onClose} title={r.id ? 'Edit alert rule' : 'New alert rule'} width="max-w-2xl">
      <form className="space-y-3" onSubmit={(e) => { e.preventDefault(); save.mutate(); }}>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Name"><Input required value={r.name ?? ''} onChange={(e) => set('name', e.target.value)} /></Field>
          <Field label="Type">
            <Select value={r.kind} onChange={(e) => set('kind', e.target.value)} className="w-full" disabled={!!r.id}>
              {Object.entries(KIND_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </Select>
          </Field>
        </div>
        <Field label="Description"><Textarea rows={2} value={r.description ?? ''} onChange={(e) => set('description', e.target.value)} /></Field>
        {r.kind === 'metric_threshold' && (
          <>
            <div className="grid grid-cols-4 gap-3">
              <Field label="Metric"><Select value={r.metric ?? ''} onChange={(e) => set('metric', e.target.value)} className="w-full">
                <option value="">Select…</option>{METRICS.map((m) => <option key={m} value={m}>{metricLabel(m)} ({m})</option>)}</Select></Field>
              <Field label="Aggregation (per minute)"><Select value={r.aggregation} onChange={(e) => set('aggregation', e.target.value)} className="w-full">
                {['avg', 'max', 'min', 'last'].map((x) => <option key={x}>{x}</option>)}</Select></Field>
              <Field label="Operator"><Select value={r.operator ?? '>'} onChange={(e) => set('operator', e.target.value)} className="w-full">
                {['>', '>=', '<', '<='].map((x) => <option key={x}>{x}</option>)}</Select></Field>
              <Field label="Threshold"><Input type="number" step="any" required value={r.threshold ?? ''} onChange={(e) => set('threshold', e.target.value)} /></Field>
            </div>
            <div className="grid grid-cols-3 gap-3">
              <Field label="Recovery threshold" hint="Hysteresis: clears only past this value"><Input type="number" step="any" value={r.recovery_threshold ?? ''} onChange={(e) => set('recovery_threshold', e.target.value)} /></Field>
              <Field label="Sustained for (seconds)" hint="0 = fire on the first breaching sample"><Input type="number" min={0} value={r.for_seconds} onChange={(e) => set('for_seconds', e.target.value)} /></Field>
              <Field label="Series filter" hint="e.g. mount=* or mount=/var*"><Input value={r.series_match ?? ''} onChange={(e) => set('series_match', e.target.value)} /></Field>
            </div>
          </>
        )}
        {r.kind === 'heartbeat' && <Field label="Missing for (seconds)"><Input type="number" min={60} required value={r.threshold ?? 300} onChange={(e) => set('threshold', e.target.value)} /></Field>}
        {r.kind === 'synthetic' && <Field label="Consecutive failures"><Input type="number" min={1} value={r.consecutive} onChange={(e) => set('consecutive', e.target.value)} /></Field>}
        <div className="grid grid-cols-2 gap-3">
          <Field label="Severity"><Select value={r.severity} onChange={(e) => set('severity', e.target.value)} className="w-full"><option value="warning">Warning</option><option value="critical">Critical</option></Select></Field>
          <Field label="Enabled"><Select value={String(r.enabled)} onChange={(e) => set('enabled', e.target.value === 'true')} className="w-full"><option value="true">Enabled</option><option value="false">Disabled</option></Select></Field>
        </div>
        <fieldset className="rounded-md border border-border p-3">
          <legend className="px-1 text-xs font-medium text-ink-2">Scope and exclusions (comma separated; empty = all)</legend>
          <div className="grid grid-cols-2 gap-3">
            <Field label="Providers"><Input value={scope.providers} onChange={(e) => setScope({ ...scope, providers: e.target.value })} placeholder="azure, digitalocean" /></Field>
            <Field label="Environments"><Input value={scope.environments} onChange={(e) => setScope({ ...scope, environments: e.target.value })} placeholder="production" /></Field>
            <Field label="OS types"><Input value={scope.os_types} onChange={(e) => setScope({ ...scope, os_types: e.target.value })} placeholder="linux, windows" /></Field>
            <Field label="Resource types"><Input value={scope.resource_types} onChange={(e) => setScope({ ...scope, resource_types: e.target.value })} placeholder="vm, server" /></Field>
            <Field label="Exclude series"><Input value={scope.excl_series} onChange={(e) => setScope({ ...scope, excl_series: e.target.value })} placeholder="mount=/mnt/scratch*" /></Field>
            <Field label="Exclude environments"><Input value={scope.excl_env} onChange={(e) => setScope({ ...scope, excl_env: e.target.value })} placeholder="development" /></Field>
          </div>
        </fieldset>
        <ErrorNote error={save.error ?? del.error} />
        <div className="flex justify-between">
          {r.id ? <Button type="button" variant="danger" onClick={() => confirm('Delete this rule?') && del.mutate()}>Delete</Button> : <span />}
          <Button type="submit" variant="primary" disabled={save.isPending}>Save rule</Button>
        </div>
      </form>
    </Dialog>
  );
}
