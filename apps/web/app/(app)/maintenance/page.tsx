'use client';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Plus } from 'lucide-react';
import { useState } from 'react';
import { PageHeader } from '@/components/shell';
import { useCan } from '@/components/session';
import { Button, Card, Dialog, Empty, ErrorNote, Field, Input, Skeleton, Table, Td, Th } from '@/components/ui';
import { api } from '@/lib/api';
import { dateTime } from '@/lib/format';

const csv = (s: string) => s.split(',').map((x) => x.trim()).filter(Boolean);

export default function Maintenance() {
  const can = useCan('maintenance.manage');
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['maintenance'], queryFn: () => api.get<any[]>('/maintenance-windows') });
  const end = useMutation({ mutationFn: (id: string) => api.del(`/maintenance-windows/${id}`), onSuccess: () => qc.invalidateQueries({ queryKey: ['maintenance'] }) });
  const [open, setOpen] = useState(false);
  return (
    <div className="mx-auto max-w-[1200px]">
      <PageHeader title="Maintenance windows" subtitle="Resources in an active window show Maintenance, do not start new alerts, and are excluded from availability."
        actions={can && <Button variant="primary" onClick={() => setOpen(true)}><Plus className="size-4" />Schedule window</Button>} />
      <ErrorNote error={q.error ?? end.error} />
      <Card bodyClassName="p-0">
        {q.isLoading ? <Skeleton className="m-4 h-32" /> : !q.data?.length ? <Empty title="No maintenance windows" /> : (
          <Table>
            <thead><tr><Th>Name</Th><Th>Starts</Th><Th>Ends</Th><Th>Scope</Th><Th>Created by</Th><Th /></tr></thead>
            <tbody>{q.data.map((m) => (
              <tr key={m.id}><Td className="font-medium">{m.name} {m.active && <span className="ml-1 rounded bg-maint-soft px-1.5 py-0.5 text-[11px] text-maint">active</span>}</Td>
                <Td className="text-xs">{dateTime(m.starts_at)}</Td><Td className="text-xs">{dateTime(m.ends_at)}</Td>
                <Td className="max-w-sm truncate text-xs text-ink-2">{JSON.stringify(m.scope)}</Td><Td className="text-xs">{m.created_by_name}</Td>
                <Td>{can && new Date(m.ends_at) > new Date() && <Button size="sm" onClick={() => end.mutate(m.id)}>End now</Button>}</Td></tr>))}</tbody>
          </Table>
        )}
      </Card>
      {open && <NewWindow onClose={() => setOpen(false)} />}
    </div>
  );
}

function NewWindow({ onClose }: { onClose: () => void }) {
  const qc = useQueryClient();
  const now = new Date(Date.now() - new Date().getTimezoneOffset() * 60e3);
  const [v, setV] = useState({ name: '', starts: now.toISOString().slice(0, 16), ends: new Date(now.getTime() + 3600e3).toISOString().slice(0, 16),
    resource_ids: '', environments: '', tags: '' });
  const m = useMutation({
    mutationFn: () => api.post('/maintenance-windows', {
      name: v.name, starts_at: new Date(v.starts).toISOString(), ends_at: new Date(v.ends).toISOString(),
      scope: Object.fromEntries(Object.entries({
        resource_ids: csv(v.resource_ids), environments: csv(v.environments),
        tags: csv(v.tags).length ? Object.fromEntries(csv(v.tags).map((t) => t.split('=') as [string, string]).map(([k, val]) => [k, val ?? ''])) : undefined,
      }).filter(([, x]) => x && (Array.isArray(x) ? x.length : true))),
    }),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['maintenance'] }); onClose(); },
  });
  return (
    <Dialog open onClose={onClose} title="Schedule maintenance window">
      <form className="space-y-3" onSubmit={(e) => { e.preventDefault(); m.mutate(); }}>
        <Field label="Name"><Input required value={v.name} onChange={(e) => setV({ ...v, name: e.target.value })} placeholder="Patch Tuesday — web tier" /></Field>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Starts"><Input type="datetime-local" required value={v.starts} onChange={(e) => setV({ ...v, starts: e.target.value })} /></Field>
          <Field label="Ends"><Input type="datetime-local" required value={v.ends} onChange={(e) => setV({ ...v, ends: e.target.value })} /></Field>
        </div>
        <p className="text-xs text-ink-3">Scope is required; organization-wide windows are not allowed.</p>
        <Field label="Resource IDs" hint="Comma separated (copy from the resource page URL)"><Input value={v.resource_ids} onChange={(e) => setV({ ...v, resource_ids: e.target.value })} /></Field>
        <Field label="Environments"><Input value={v.environments} onChange={(e) => setV({ ...v, environments: e.target.value })} placeholder="staging" /></Field>
        <Field label="Tags" hint="key=value, comma separated"><Input value={v.tags} onChange={(e) => setV({ ...v, tags: e.target.value })} placeholder="team=web" /></Field>
        <ErrorNote error={m.error} />
        <div className="flex justify-end"><Button type="submit" variant="primary" disabled={m.isPending}>Schedule</Button></div>
      </form>
    </Dialog>
  );
}
