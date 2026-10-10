'use client';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { PageHeader } from '@/components/shell';
import { useCan, useMe } from '@/components/session';
import { Button, Card, ErrorNote, Field, Input, Select, Table, Tabs, Td, Th } from '@/components/ui';
import { api } from '@/lib/api';
import { dateTime, relTime } from '@/lib/format';

const ROLES = [['org_admin', 'Organization administrator'], ['infra_admin', 'Infrastructure administrator'], ['operator', 'Operator'], ['viewer', 'Viewer']];

export default function Settings() {
  const canUsers = useCan('users.manage');
  const canAudit = useCan('audit.read');
  const [tab, setTab] = useState<'members' | 'policy' | 'audit'>('members');
  return (
    <div className="mx-auto max-w-[1200px]">
      <PageHeader title="Settings" />
      <div className="mb-4"><Tabs value={tab} onChange={setTab} items={[{ value: 'members', label: 'Members' }, { value: 'policy', label: 'Heartbeat policy' }, ...(canAudit ? [{ value: 'audit' as const, label: 'Audit log' }] : [])]} /></div>
      {tab === 'members' && <Members canEdit={canUsers} />}
      {tab === 'policy' && <Policy />}
      {tab === 'audit' && canAudit && <Audit />}
    </div>
  );
}

function Members({ canEdit }: { canEdit: boolean }) {
  const me = useMe();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['members'], queryFn: () => api.get<any[]>('/members') });
  const [v, setV] = useState({ email: '', display_name: '', role: 'viewer' });
  const invite = useMutation({ mutationFn: () => api.post('/members', v), onSuccess: () => { setV({ email: '', display_name: '', role: 'viewer' }); qc.invalidateQueries({ queryKey: ['members'] }); } });
  const change = useMutation({ mutationFn: (x: { id: string; role: string }) => api.patch(`/members/${x.id}`, { role: x.role }), onSuccess: () => qc.invalidateQueries({ queryKey: ['members'] }) });
  const remove = useMutation({ mutationFn: (id: string) => api.del(`/members/${id}`), onSuccess: () => qc.invalidateQueries({ queryKey: ['members'] }) });
  return (
    <Card title="Members" subtitle="Users sign in with your identity provider (OIDC); invite them by email first." bodyClassName="p-0">
      <ErrorNote error={invite.error ?? change.error ?? remove.error} />
      <Table>
        <thead><tr><Th>Name</Th><Th>Email</Th><Th>Role</Th><Th>SSO</Th><Th>Last sign-in</Th><Th /></tr></thead>
        <tbody>{q.data?.map((m) => (
          <tr key={m.id}><Td className="font-medium">{m.display_name}</Td><Td className="text-xs">{m.email}</Td>
            <Td>{canEdit && m.id !== me.user.id ? (
              <Select aria-label={`Role for ${m.email}`} value={m.role} onChange={(e) => change.mutate({ id: m.id, role: e.target.value })}>{ROLES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</Select>
            ) : <span className="text-xs">{ROLES.find((r) => r[0] === m.role)?.[1]}</span>}</Td>
            <Td className="text-xs">{m.sso_linked ? 'linked' : '—'}</Td><Td className="text-xs text-ink-2">{relTime(m.last_login_at)}</Td>
            <Td>{canEdit && m.id !== me.user.id && <Button size="sm" variant="ghost" onClick={() => confirm(`Remove ${m.email}?`) && remove.mutate(m.id)}>Remove</Button>}</Td></tr>))}</tbody>
      </Table>
      {canEdit && (
        <form className="flex flex-wrap items-end gap-2 border-t border-border p-3" onSubmit={(e) => { e.preventDefault(); invite.mutate(); }}>
          <Field label="Email"><Input type="email" required value={v.email} onChange={(e) => setV({ ...v, email: e.target.value })} className="w-64" /></Field>
          <Field label="Name"><Input required value={v.display_name} onChange={(e) => setV({ ...v, display_name: e.target.value })} className="w-48" /></Field>
          <Field label="Role"><Select value={v.role} onChange={(e) => setV({ ...v, role: e.target.value })}>{ROLES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</Select></Field>
          <Button type="submit" variant="primary" disabled={invite.isPending}>Invite</Button>
        </form>
      )}
    </Card>
  );
}

function Policy() {
  const can = useCan('monitoring.configure');
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['policy'], queryFn: () => api.get<any>('/monitoring-policy') });
  const [p, setP] = useState<any>(null);
  useEffect(() => { if (q.data) setP({ ...q.data, linux: (q.data.watched_services?.linux ?? []).join(', '), windows: (q.data.watched_services?.windows ?? []).join(', ') }); }, [q.data]);
  const save = useMutation({
    mutationFn: () => api.put('/monitoring-policy', {
      heartbeat_interval_s: Number(p.heartbeat_interval_s), heartbeat_warning_s: Number(p.heartbeat_warning_s), heartbeat_critical_s: Number(p.heartbeat_critical_s),
      metrics_interval_s: Number(p.metrics_interval_s), flap_window_s: Number(p.flap_window_s), flap_threshold: Number(p.flap_threshold), discover_services: !!p.discover_services,
      watched_services: { linux: p.linux.split(',').map((s: string) => s.trim()).filter(Boolean), windows: p.windows.split(',').map((s: string) => s.trim()).filter(Boolean) },
    }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['policy'] }),
  });
  if (!p) return null;
  const num = (k: string, label: string, hint?: string) => <Field label={label} hint={hint}><Input type="number" disabled={!can} value={p[k]} onChange={(e) => setP({ ...p, [k]: e.target.value })} /></Field>;
  return (
    <Card title="Default monitoring policy" subtitle="Initial values follow common practice; adjust to your environment. Applies to agents on their next upload.">
      <form className="grid grid-cols-1 gap-3 md:grid-cols-3" onSubmit={(e) => { e.preventDefault(); save.mutate(); }}>
        {num('heartbeat_interval_s', 'Agent heartbeat interval (s)')}
        {num('heartbeat_warning_s', 'Warning after (s) without heartbeat')}
        {num('heartbeat_critical_s', 'Critical after (s) without heartbeat')}
        {num('metrics_interval_s', 'Metric collection interval (s)')}
        {num('flap_window_s', 'Flap detection window (s)')}
        {num('flap_threshold', 'State changes that count as flapping')}
        <Field label="Required Linux services on every host" hint="systemd unit names"><Input disabled={!can} value={p.linux} onChange={(e) => setP({ ...p, linux: e.target.value })} /></Field>
        <Field label="Required Windows services on every host" hint="service names, e.g. W32Time"><Input disabled={!can} value={p.windows} onChange={(e) => setP({ ...p, windows: e.target.value })} /></Field>
        <label className="flex items-center gap-2 pt-5 text-xs"><input type="checkbox" disabled={!can} checked={!!p.discover_services} onChange={(e) => setP({ ...p, discover_services: e.target.checked })} />Discover all services (informational)</label>
        <div className="md:col-span-3"><ErrorNote error={save.error} /></div>
        {can && <div className="md:col-span-3"><Button type="submit" variant="primary" disabled={save.isPending}>Save policy</Button></div>}
      </form>
    </Card>
  );
}

function Audit() {
  const q = useQuery({ queryKey: ['audit'], queryFn: () => api.get<any[]>('/audit-logs?limit=300') });
  return (
    <Card title="Audit log" subtitle="Append-only record of administrative and security-relevant actions" bodyClassName="p-0">
      <Table className="max-h-[65vh]">
        <thead><tr><Th>Time</Th><Th>Actor</Th><Th>Action</Th><Th>Target</Th><Th>IP</Th><Th>Details</Th></tr></thead>
        <tbody>{q.data?.map((a) => (
          <tr key={a.id}><Td className="whitespace-nowrap text-xs">{dateTime(a.at)}</Td><Td className="text-xs">{a.actor_label ?? a.actor_type}</Td><Td className="font-mono text-[12px]">{a.action}</Td>
            <Td className="text-xs text-ink-2">{a.target_type}</Td><Td className="text-xs text-ink-3">{a.ip}</Td>
            <Td className="max-w-sm truncate font-mono text-[11px] text-ink-3" title={JSON.stringify(a.details)}>{JSON.stringify(a.details)}</Td></tr>))}</tbody>
      </Table>
    </Card>
  );
}
