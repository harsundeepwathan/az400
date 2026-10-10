'use client';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Plus, Send } from 'lucide-react';
import { useEffect, useState } from 'react';
import { PageHeader } from '@/components/shell';
import { useCan } from '@/components/session';
import { Button, Card, Dialog, Empty, ErrorNote, Field, Input, Select, Skeleton, Table, Td, Th } from '@/components/ui';
import { api } from '@/lib/api';
import { relTime } from '@/lib/format';

const KINDS: Record<string, string> = { slack: 'Slack', teams: 'Microsoft Teams', email: 'Email', webhook: 'Webhook', telegram: 'Telegram' };

export default function Notifications() {
  const can = useCan('monitoring.configure');
  const qc = useQueryClient();
  const channels = useQuery({ queryKey: ['channels'], queryFn: () => api.get<any[]>('/notification-channels') });
  const policies = useQuery({ queryKey: ['escalation'], queryFn: () => api.get<any[]>('/escalation-policies') });
  const test = useMutation({ mutationFn: (id: string) => api.post<any>(`/notification-channels/${id}/test`) });
  const toggle = useMutation({ mutationFn: (c: any) => api.patch(`/notification-channels/${c.id}`, { enabled: !c.enabled }), onSuccess: () => qc.invalidateQueries({ queryKey: ['channels'] }) });
  const del = useMutation({ mutationFn: (id: string) => api.del(`/notification-channels/${id}`), onSuccess: () => qc.invalidateQueries({ queryKey: ['channels'] }) });
  const [open, setOpen] = useState(false);
  return (
    <div className="mx-auto max-w-[1200px] space-y-4">
      <PageHeader title="Notifications" subtitle="Channels receive incident open, escalation, repeat and recovery notifications through the escalation policy."
        actions={can && <Button variant="primary" onClick={() => setOpen(true)}><Plus className="size-4" />Add channel</Button>} />
      <ErrorNote error={channels.error ?? test.error ?? del.error} />
      {test.data && <div className={test.data.ok ? 'text-xs text-good-ink' : 'text-xs text-critical-ink'} role="status">{test.data.ok ? 'Test notification sent.' : `Test failed: ${test.data.error}`}</div>}
      <Card title="Channels" bodyClassName="p-0">
        {channels.isLoading ? <Skeleton className="m-4 h-24" /> : !channels.data?.length ? <Empty title="No channels">Add Slack, Teams, email, webhook or Telegram.</Empty> : (
          <Table>
            <thead><tr><Th>Name</Th><Th>Type</Th><Th>Last sent</Th><Th>Failures (7d)</Th><Th>Enabled</Th><Th /></tr></thead>
            <tbody>{channels.data.map((c) => (
              <tr key={c.id}><Td className="font-medium">{c.name}</Td><Td className="text-xs">{KINDS[c.kind]}</Td><Td className="text-xs">{relTime(c.last_sent_at)}</Td>
                <Td className={c.failed_7d ? 'text-xs text-critical-ink' : 'text-xs text-ink-3'}>{c.failed_7d}</Td><Td className="text-xs">{c.enabled ? 'yes' : 'no'}</Td>
                <Td className="space-x-1 text-right">{can && <>
                  <Button size="sm" onClick={() => test.mutate(c.id)} disabled={test.isPending}><Send className="size-3" />Test</Button>
                  <Button size="sm" onClick={() => toggle.mutate(c)}>{c.enabled ? 'Disable' : 'Enable'}</Button>
                  <Button size="sm" variant="ghost" onClick={() => confirm('Delete channel?') && del.mutate(c.id)}>Delete</Button></>}</Td></tr>))}</tbody>
          </Table>
        )}
      </Card>
      {policies.data?.map((p) => <PolicyEditor key={p.id} policy={p} channels={channels.data ?? []} canEdit={can} />)}
      {open && <ChannelDialog onClose={() => setOpen(false)} />}
    </div>
  );
}

function PolicyEditor({ policy, channels, canEdit }: { policy: any; channels: any[]; canEdit: boolean }) {
  const qc = useQueryClient();
  const [steps, setSteps] = useState<{ delay_seconds: number; channel_ids: string[] }[]>(policy.steps);
  const [repeat, setRepeat] = useState<number | null>(policy.repeat_interval_s);
  const [resolve, setResolve] = useState<boolean>(policy.notify_on_resolve);
  useEffect(() => { setSteps(policy.steps); }, [policy.steps]);
  const save = useMutation({
    mutationFn: () => api.put(`/escalation-policies/${policy.id}`, { name: policy.name, steps, repeat_interval_s: repeat, notify_on_resolve: resolve }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['escalation'] }),
  });
  return (
    <Card title={`Escalation policy: ${policy.name}`} subtitle="Applies to incidents unless a rule names another policy. Escalation stops on acknowledgement.">
      <div className="space-y-2">
        {steps.length === 0 && <p className="text-xs text-warning-ink">No steps: incidents are recorded but nobody is notified.</p>}
        {steps.map((s, i) => (
          <div key={i} className="flex flex-wrap items-end gap-2 rounded-md border border-border p-2">
            <span className="pb-2 text-xs font-medium">Step {i + 1}</span>
            <Field label="After (minutes unacknowledged)"><Input type="number" min={0} disabled={!canEdit} value={s.delay_seconds / 60} className="w-28"
              onChange={(e) => setSteps(steps.map((x, j) => (j === i ? { ...x, delay_seconds: Math.round(Number(e.target.value) * 60) } : x)))} /></Field>
            <Field label="Notify channels">
              <div className="flex flex-wrap gap-2 pb-1.5">{channels.map((c) => (
                <label key={c.id} className="flex items-center gap-1 text-xs"><input type="checkbox" disabled={!canEdit} checked={s.channel_ids.includes(c.id)}
                  onChange={(e) => setSteps(steps.map((x, j) => (j === i ? { ...x, channel_ids: e.target.checked ? [...x.channel_ids, c.id] : x.channel_ids.filter((y) => y !== c.id) } : x)))} />{c.name}</label>))}</div>
            </Field>
            {canEdit && <Button size="sm" variant="ghost" onClick={() => setSteps(steps.filter((_, j) => j !== i))}>Remove</Button>}
          </div>
        ))}
        {canEdit && (
          <div className="flex flex-wrap items-end gap-3 pt-1">
            <Button size="sm" onClick={() => setSteps([...steps, { delay_seconds: steps.length ? steps[steps.length - 1]!.delay_seconds + 900 : 0, channel_ids: [] }])}>Add step</Button>
            <Field label="Repeat while unacknowledged"><Select value={repeat ?? ''} onChange={(e) => setRepeat(e.target.value ? Number(e.target.value) : null)}>
              <option value="">Never</option><option value="900">Every 15 min</option><option value="1800">Every 30 min</option><option value="3600">Every hour</option></Select></Field>
            <label className="flex items-center gap-1.5 pb-2 text-xs"><input type="checkbox" checked={resolve} onChange={(e) => setResolve(e.target.checked)} />Send recovery notifications</label>
            <div className="flex-1" />
            <Button variant="primary" onClick={() => save.mutate()} disabled={save.isPending}>Save policy</Button>
          </div>
        )}
        <ErrorNote error={save.error} />
      </div>
    </Card>
  );
}

function ChannelDialog({ onClose }: { onClose: () => void }) {
  const qc = useQueryClient();
  const [kind, setKind] = useState('slack');
  const [v, setV] = useState<Record<string, string>>({});
  const m = useMutation({
    mutationFn: () => {
      const base = { kind, name: v.name };
      const body = kind === 'email' ? { ...base, config: { to: (v.to ?? '').split(/[\s,]+/).filter(Boolean) } }
        : kind === 'telegram' ? { ...base, config: { chat_id: v.chat_id }, secret: { bot_token: v.bot_token } }
        : kind === 'webhook' ? { ...base, secret: { url: v.url, signing_secret: v.signing_secret || undefined } }
        : { ...base, secret: { webhook_url: v.webhook_url } };
      return api.post('/notification-channels', body);
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['channels'] }); onClose(); },
  });
  const f = (k: string, label: string, props: Record<string, unknown> = {}) => (
    <Field label={label}><Input required value={v[k] ?? ''} onChange={(e) => setV({ ...v, [k]: e.target.value })} {...props} /></Field>
  );
  return (
    <Dialog open onClose={onClose} title="Add notification channel">
      <form className="space-y-3" onSubmit={(e) => { e.preventDefault(); m.mutate(); }}>
        <Field label="Type"><Select value={kind} onChange={(e) => setKind(e.target.value)} className="w-full">{Object.entries(KINDS).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</Select></Field>
        {f('name', 'Name', { placeholder: '#noc-alerts' })}
        {(kind === 'slack' || kind === 'teams') && f('webhook_url', kind === 'teams' ? 'Teams Workflows webhook URL' : 'Slack incoming webhook URL', { type: 'password', autoComplete: 'off' })}
        {kind === 'webhook' && <>{f('url', 'HTTPS endpoint', { type: 'url' })}<Field label="Signing secret (optional, 16+ chars)" hint="Requests carry X-Skywatch-Signature: v1=HMAC-SHA256(timestamp.body)">
          <Input type="password" autoComplete="off" value={v.signing_secret ?? ''} onChange={(e) => setV({ ...v, signing_secret: e.target.value })} /></Field></>}
        {kind === 'email' && f('to', 'Recipients', { placeholder: 'oncall@example.com, noc@example.com' })}
        {kind === 'telegram' && <>{f('bot_token', 'Bot token', { type: 'password', autoComplete: 'off' })}{f('chat_id', 'Chat ID')}</>}
        <p className="text-xs text-ink-3">Secret values are encrypted and cannot be viewed after saving.</p>
        <ErrorNote error={m.error} />
        <div className="flex justify-end"><Button type="submit" variant="primary" disabled={m.isPending}>Add channel</Button></div>
      </form>
    </Dialog>
  );
}
