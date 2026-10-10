'use client';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ArrowLeft } from 'lucide-react';
import Link from 'next/link';
import { useParams, useRouter } from 'next/navigation';
import { useState } from 'react';
import { useCan } from '@/components/session';
import { ProviderTag, StateBadge } from '@/components/status';
import { Button, Card, Dialog, ErrorNote, Field, Input, KV, Mono, Skeleton, Table, Td, Th, cx } from '@/components/ui';
import { api } from '@/lib/api';
import { dateTime, relTime } from '@/lib/format';
import { accountState } from '@/lib/state';

export default function AccountDetail() {
  const { id } = useParams<{ id: string }>();
  const router = useRouter();
  const qc = useQueryClient();
  const canManage = useCan('accounts.manage');
  const q = useQuery({ queryKey: ['account', id], queryFn: () => api.get<any>(`/accounts/${id}`), refetchInterval: 20_000 });
  const refresh = () => qc.invalidateQueries({ queryKey: ['account', id] });
  const validate = useMutation({ mutationFn: () => api.post(`/accounts/${id}/validate`), onSuccess: refresh });
  const activate = useMutation({ mutationFn: () => api.post(`/accounts/${id}/activate`), onSuccess: refresh });
  const disable = useMutation({ mutationFn: () => api.post(`/accounts/${id}/disable`), onSuccess: refresh });
  const del = useMutation({ mutationFn: () => api.del(`/accounts/${id}`), onSuccess: () => router.push('/accounts') });
  const [rotate, setRotate] = useState(false);
  if (q.error) return <ErrorNote error={q.error} />;
  if (!q.data) return <Skeleton className="h-96" />;
  const a = q.data;
  const rep = a.permission_report ?? {};
  const isDemo = a.auth_method === 'demo';
  return (
    <div className="mx-auto max-w-[1300px]">
      <Link href="/accounts" className="mb-3 inline-flex items-center gap-1 text-xs text-ink-3 hover:text-ink"><ArrowLeft className="size-3.5" />Cloud accounts</Link>
      <div className="mb-4 flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2"><h1 className="text-lg font-semibold">{a.name}</h1><StateBadge state={accountState(a.status)} /><span className="text-xs text-ink-3">{a.status}</span></div>
          <p className="text-xs text-ink-3"><ProviderTag provider={a.provider} /> · {a.credential_hint}</p>
          {a.status_reason && <p className="mt-1 text-[13px] text-critical-ink">{a.status_reason}</p>}
        </div>
        {canManage && !isDemo && (
          <div className="flex flex-wrap gap-2">
            <Button onClick={() => validate.mutate()} disabled={validate.isPending}>{validate.isPending ? 'Validating…' : 'Validate'}</Button>
            {(a.status === 'validating' || a.status === 'pending' || a.status === 'disabled') && <Button variant="primary" onClick={() => activate.mutate()}>Activate</Button>}
            <Button onClick={() => setRotate(true)}>Rotate credentials</Button>
            {a.status !== 'disabled' && <Button onClick={() => disable.mutate()}>Disable</Button>}
            <Button variant="danger" onClick={() => confirm('Delete this account and all its resources and history?') && del.mutate()}>Delete</Button>
          </div>
        )}
      </div>
      <ErrorNote error={validate.error ?? activate.error ?? disable.error ?? del.error} />
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <Card title="Summary">
          <KV items={[
            ['Status', a.status], ['External ID', a.external_id ? <Mono key="e">{a.external_id}</Mono> : '—'], ['Auth method', a.auth_method],
            ['Last validated', dateTime(a.last_validated_at)], ['Last discovery', relTime(a.last_discovery_at)], ['Last success', relTime(a.last_success_at)],
            ['Throttle events', a.throttle_events ? `${a.throttle_events} (last ${relTime(a.last_throttled_at)})` : 'none'],
            ['Configuration', <Mono key="c" className="break-all text-[11px]">{JSON.stringify(a.config)}</Mono>],
          ]} />
        </Card>
        <Card title="Permission report" className="lg:col-span-2" bodyClassName="p-0">
          {!rep.checks ? <p className="p-4 text-xs text-ink-3">{isDemo ? 'Demo account — no credentials.' : 'Not validated yet.'}</p> : (
            <ul className="divide-y divide-border">{rep.checks.map((c: any) => (
              <li key={c.check} className="px-4 py-2 text-[13px]">
                <span className={cx('mr-2 text-xs font-semibold', c.ok ? 'text-good-ink' : 'text-critical-ink')}>{c.ok ? 'PASS' : 'FAIL'}</span>{c.check}
                {c.detail && <div className="text-xs text-ink-3">{c.detail}</div>}{c.missing && <div className="text-xs text-warning-ink">Fix: {c.missing}</div>}
              </li>))}</ul>
          )}
        </Card>
        <Card title="Collection runs" subtitle="Most recent 50" className="lg:col-span-3" bodyClassName="p-0">
          <Table className="max-h-96">
            <thead><tr><Th>Job</Th><Th>Started</Th><Th>Status</Th><Th>API calls</Th><Th>Throttled</Th><Th>Items</Th><Th>Error</Th></tr></thead>
            <tbody>{a.runs.map((r: any, i: number) => (
              <tr key={i}><Td className="text-xs">{r.kind}</Td><Td className="whitespace-nowrap text-xs">{dateTime(r.started_at)}</Td>
                <Td><span className={cx('text-xs font-medium', r.status === 'ok' ? 'text-good-ink' : r.status === 'skipped' ? 'text-ink-3' : 'text-critical-ink')}>{r.status}</span></Td>
                <Td className="tabular text-xs">{r.api_calls}</Td><Td className="tabular text-xs">{r.throttled_calls}</Td><Td className="tabular text-xs">{r.items}</Td>
                <Td className="max-w-md truncate text-xs text-ink-2" title={r.error ?? ''}>{r.error}</Td></tr>))}</tbody>
          </Table>
        </Card>
      </div>
      <RotateDialog open={rotate} onClose={() => setRotate(false)} provider={a.provider} id={id} onDone={refresh} />
    </div>
  );
}

function RotateDialog({ open, onClose, provider, id, onDone }: { open: boolean; onClose: () => void; provider: string; id: string; onDone: () => void }) {
  const [v, setV] = useState<Record<string, string>>({});
  const m = useMutation({
    mutationFn: () => api.patch(`/accounts/${id}`, { credentials: v }),
    onSuccess: () => { setV({}); onClose(); onDone(); },
  });
  const fields = provider === 'azure' ? [['tenant_id', 'Tenant ID'], ['client_id', 'Client ID'], ['client_secret', 'New client secret']]
    : provider === 'digitalocean' ? [['token', 'New API token']] : [['access_key_id', 'AccessKey ID'], ['access_key_secret', 'New AccessKey secret']];
  return (
    <Dialog open={open} onClose={onClose} title="Rotate credentials">
      <form className="space-y-3" onSubmit={(e) => { e.preventDefault(); m.mutate(); }}>
        <p className="text-xs text-ink-3">The account returns to “pending” until validated with the new credentials.</p>
        {fields.map(([k, label]) => (
          <Field key={k} label={label!}><Input required type={k!.includes('secret') || k === 'token' ? 'password' : 'text'} autoComplete="off" value={v[k!] ?? ''} onChange={(e) => setV({ ...v, [k!]: e.target.value })} /></Field>
        ))}
        <ErrorNote error={m.error} />
        <div className="flex justify-end"><Button variant="primary" type="submit" disabled={m.isPending}>Save</Button></div>
      </form>
    </Dialog>
  );
}
