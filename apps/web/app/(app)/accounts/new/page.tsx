'use client';
import { useMutation } from '@tanstack/react-query';
import { Check, CheckCircle2, CircleSlash, XCircle } from 'lucide-react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { PageHeader } from '@/components/shell';
import { Button, Card, Empty, ErrorNote, Field, Input, Mono, Select, Table, Td, Textarea, Th, cx } from '@/components/ui';
import { api } from '@/lib/api';
import { TYPE_LABEL } from '@/lib/state';

type Provider = 'azure' | 'digitalocean' | 'alibaba';
const STEPS = ['Provider', 'Credentials', 'Validate', 'Discover', 'Capabilities', 'Select resources', 'Activate'];

const PROVIDERS: { id: Provider | 'aws' | 'gcp' | 'vmware'; name: string; note: string; available: boolean }[] = [
  { id: 'azure', name: 'Microsoft Azure', note: 'Entra ID application with Reader + Monitoring Reader', available: true },
  { id: 'digitalocean', name: 'DigitalOcean', note: 'Personal access token with read-only custom scopes', available: true },
  { id: 'alibaba', name: 'Alibaba Cloud', note: 'RAM user AccessKey with a read-only policy', available: true },
  { id: 'aws', name: 'Amazon Web Services', note: 'Not implemented yet', available: false },
  { id: 'gcp', name: 'Google Cloud', note: 'Not implemented yet', available: false },
  { id: 'vmware', name: 'VMware vSphere', note: 'Not implemented yet — use the Skywatch agent', available: false },
];

const lines = (s: string) => s.split(/[\s,]+/).map((x) => x.trim()).filter(Boolean);

export default function NewAccount() {
  const router = useRouter();
  const [step, setStep] = useState(0);
  const [provider, setProvider] = useState<Provider>('azure');
  const [form, setForm] = useState<Record<string, string>>({ auth_method: 'client_secret', cloud: 'AzurePublic' });
  const [accountId, setAccountId] = useState<string>('');
  const [validation, setValidation] = useState<any>(null);
  const [discovered, setDiscovered] = useState<any[] | null>(null);
  const [excluded, setExcluded] = useState<Set<string>>(new Set());
  const set = (k: string) => (e: { target: { value: string } }) => setForm((f) => ({ ...f, [k]: e.target.value }));

  const create = useMutation({
    mutationFn: () => {
      const base = { provider, name: form.name };
      const body = provider === 'azure'
        ? { ...base, auth_method: form.auth_method, tenant_id: form.tenant_id, client_id: form.client_id || undefined, client_secret: form.client_secret || undefined,
            certificate_pem: form.certificate_pem || undefined, subscription_ids: lines(form.subscription_ids ?? ''),
            log_analytics_workspace_ids: lines(form.workspace_ids ?? ''), cloud: form.cloud }
        : provider === 'digitalocean' ? { ...base, token: form.token }
        : { ...base, access_key_id: form.access_key_id, access_key_secret: form.access_key_secret, security_token: form.security_token || undefined,
            account_uid: form.account_uid || undefined, regions: lines(form.regions ?? '') };
      return api.post<{ id: string }>('/accounts', body);
    },
    onSuccess: (a) => {
      setAccountId(a.id);
      // Secrets leave the browser's memory as soon as they are stored.
      setForm((f) => ({ ...f, client_secret: '', certificate_pem: '', token: '', access_key_secret: '', security_token: '' }));
      setStep(2);
      validate.mutate(a.id);
    },
  });
  const validate = useMutation({ mutationFn: (id: string) => api.post<any>(`/accounts/${id}/validate`), onSuccess: setValidation });
  const discover = useMutation({ mutationFn: () => api.post<any>(`/accounts/${accountId}/discover`), onSuccess: (r) => setDiscovered(r.resources ?? []) });
  const activate = useMutation({
    mutationFn: async () => {
      if (excluded.size) await api.patch(`/accounts/${accountId}`, { excluded_resource_ids: [...excluded] });
      await api.post(`/accounts/${accountId}/activate`);
    },
    onSuccess: () => router.push(`/accounts/${accountId}`),
  });

  return (
    <div className="mx-auto max-w-4xl">
      <PageHeader title="Connect a cloud account" subtitle="Skywatch uses read-only access. Nothing is changed in your cloud." />
      <ol className="mb-5 flex flex-wrap gap-1.5" aria-label="Progress">
        {STEPS.map((s, i) => (
          <li key={s} aria-current={i === step ? 'step' : undefined} className={cx('flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs',
            i === step ? 'border-accent bg-accent-soft font-medium text-ink' : i < step ? 'border-border text-ink-2' : 'border-border text-ink-3')}>
            {i < step ? <Check className="size-3 text-good" aria-hidden /> : <span className="tabular">{i + 1}</span>}{s}
          </li>
        ))}
      </ol>

      {step === 0 && (
        <Card title="1. Select a provider">
          <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
            {PROVIDERS.map((p) => (
              <button key={p.id} disabled={!p.available} onClick={() => { setProvider(p.id as Provider); setStep(1); }}
                className={cx('rounded-lg border p-3 text-left', p.available ? 'border-border hover:border-accent hover:bg-accent-soft' : 'cursor-not-allowed border-dashed border-border opacity-60')}>
                <div className="font-medium">{p.name}</div><div className="text-xs text-ink-3">{p.note}</div>
              </button>
            ))}
          </div>
        </Card>
      )}

      {step === 1 && (
        <Card title="2. Credentials" subtitle="Encrypted on receipt with a per-account data key; never shown again.">
          <form className="space-y-3" onSubmit={(e) => { e.preventDefault(); create.mutate(); }}>
            <Field label="Display name"><Input required value={form.name ?? ''} onChange={set('name')} placeholder="e.g. Azure — Production" /></Field>
            {provider === 'azure' && <AzureFields form={form} set={set} />}
            {provider === 'digitalocean' && <DOFields form={form} set={set} />}
            {provider === 'alibaba' && <AlibabaFields form={form} set={set} />}
            <ErrorNote error={create.error} />
            <div className="flex justify-between pt-2">
              <Button type="button" variant="ghost" onClick={() => setStep(0)}>Back</Button>
              <Button type="submit" variant="primary" disabled={create.isPending}>{create.isPending ? 'Saving…' : 'Save and validate'}</Button>
            </div>
          </form>
        </Card>
      )}

      {step === 2 && (
        <Card title="3. Validate connectivity and permissions">
          {validate.isPending && <p className="text-sm text-ink-2">Contacting the provider with the stored credentials…</p>}
          <ErrorNote error={validate.error} />
          {validation && <Checks v={validation} />}
          <div className="mt-4 flex justify-between">
            <Button variant="ghost" onClick={() => setStep(1)}>Edit credentials</Button>
            <div className="flex gap-2">
              <Button onClick={() => validate.mutate(accountId)} disabled={validate.isPending}>Re-run validation</Button>
              <Button variant="primary" disabled={!validation?.ok} onClick={() => { setStep(3); discover.mutate(); }}>Continue</Button>
            </div>
          </div>
        </Card>
      )}

      {step === 3 && (
        <Card title="4. Discover resources">
          {discover.isPending && <p className="text-sm text-ink-2">Listing resources…</p>}
          <ErrorNote error={discover.error} />
          {discovered && <p className="text-sm">{discovered.length} resources found across {new Set(discovered.map((d) => d.region)).size} regions.</p>}
          <div className="mt-4 flex justify-end gap-2">
            <Button onClick={() => discover.mutate()} disabled={discover.isPending}>Refresh</Button>
            <Button variant="primary" disabled={!discovered} onClick={() => setStep(4)}>Continue</Button>
          </div>
        </Card>
      )}

      {step === 4 && (
        <Card title="5. Monitoring capabilities and prerequisites" subtitle="What this integration can and cannot observe. Gaps are shown in the UI, never filled with assumed values.">
          <Table>
            <thead><tr><Th>Capability</Th><Th>Status</Th><Th>Requires</Th></tr></thead>
            <tbody>{(validation?.capabilities ?? []).map((c: any) => (
              <tr key={c.key}><Td><div>{c.title}</div>{c.notes && <div className="text-xs text-ink-3">{c.notes}</div>}</Td>
                <Td><span className={cx('text-xs font-medium', c.status === 'implemented' ? 'text-good-ink' : c.status === 'experimental' ? 'text-warning-ink' : 'text-ink-3')}>{c.status.replace('_', ' ')}</span></Td>
                <Td className="text-xs text-ink-2">{(c.requires ?? []).join('; ') || '—'}</Td></tr>))}</tbody>
          </Table>
          <div className="mt-4 flex justify-end"><Button variant="primary" onClick={() => setStep(5)}>Continue</Button></div>
        </Card>
      )}

      {step === 5 && (
        <Card title="6. Select resources to monitor" subtitle="Unselected resources stay in inventory without alerting. The default alert rules and monitoring policy apply; tune them under Alert rules." bodyClassName="p-0">
          {!discovered?.length ? <Empty title="Nothing discovered">New resources are picked up automatically every 5 minutes after activation.</Empty> : (
            <Table className="max-h-96">
              <thead><tr><Th className="w-8"><input type="checkbox" aria-label="Select all" checked={excluded.size === 0}
                onChange={(e) => setExcluded(e.target.checked ? new Set() : new Set(discovered.map((d) => d.provider_resource_id)))} /></Th><Th>Name</Th><Th>Type</Th><Th>Region</Th><Th>Power</Th></tr></thead>
              <tbody>{discovered.map((d) => (
                <tr key={d.provider_resource_id}>
                  <Td><input type="checkbox" aria-label={`Monitor ${d.name}`} checked={!excluded.has(d.provider_resource_id)} onChange={() => setExcluded((s) => {
                    const n = new Set(s); if (n.has(d.provider_resource_id)) n.delete(d.provider_resource_id); else n.add(d.provider_resource_id); return n; })} /></Td>
                  <Td>{d.name}</Td><Td className="text-xs">{TYPE_LABEL[d.type] ?? d.type}</Td><Td className="text-xs">{d.region}</Td><Td className="text-xs">{d.power_state}</Td>
                </tr>))}</tbody>
            </Table>
          )}
          <div className="flex justify-end p-3"><Button variant="primary" onClick={() => setStep(6)}>Continue</Button></div>
        </Card>
      )}

      {step === 6 && (
        <Card title="7. Activate monitoring">
          <p className="text-sm text-ink-2">Collection starts within a minute: discovery every 5 minutes, metrics every 2 minutes, provider health and events every 5 minutes. {excluded.size ? `${excluded.size} resources will be inventoried but not monitored.` : ''}</p>
          <ErrorNote error={activate.error} />
          <div className="mt-4 flex justify-end"><Button variant="primary" onClick={() => activate.mutate()} disabled={activate.isPending}>Activate monitoring</Button></div>
        </Card>
      )}
      <p className="mt-4 text-xs text-ink-3">Least-privilege setup guides: <Link className="text-accent hover:underline" href="https://github.com/harsundeepwathan/az400/tree/feat/platform-foundation/docs/onboarding">docs/onboarding</Link></p>
    </div>
  );
}

function Checks({ v }: { v: any }) {
  if (v.demo) return <p className="text-sm">Demo account: synthetic data, no credentials to validate.</p>;
  const rep = v.report ?? { checks: [] };
  return (
    <div>
      <div className={cx('mb-3 flex items-center gap-2 text-sm font-medium', v.ok ? 'text-good-ink' : 'text-critical-ink')}>
        {v.ok ? <CheckCircle2 className="size-4" /> : <XCircle className="size-4" />}{v.ok ? 'Validation passed' : v.error ?? 'Validation found problems'}
      </div>
      {rep.identity && <p className="mb-2 text-xs text-ink-3">Authenticated as <Mono>{rep.identity}</Mono>{rep.scopes?.length ? ` · ${rep.scopes.join(', ')}` : ''}</p>}
      <ul className="divide-y divide-border rounded-md border border-border">
        {rep.checks.map((c: any) => (
          <li key={c.check} className="flex gap-2 px-3 py-2 text-[13px]">
            {c.ok ? <CheckCircle2 className="mt-0.5 size-4 shrink-0 text-good" aria-label="passed" /> : c.missing?.startsWith('Optional') ? <CircleSlash className="mt-0.5 size-4 shrink-0 text-ink-3" aria-label="optional" /> : <XCircle className="mt-0.5 size-4 shrink-0 text-critical" aria-label="failed" />}
            <div className="min-w-0">
              <div>{c.check}</div>
              {c.detail && <div className="break-words text-xs text-ink-3">{c.detail}</div>}
              {c.missing && <div className="text-xs text-warning-ink">Fix: {c.missing}</div>}
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}

type F = { form: Record<string, string>; set: (k: string) => (e: { target: { value: string } }) => void };

function AzureFields({ form, set }: F) {
  return (
    <>
      <div className="rounded-md bg-surface-2 p-3 text-xs text-ink-2">
        Create an Entra ID app registration and grant it <strong>Reader</strong> and <strong>Monitoring Reader</strong> on the subscriptions (or a management group),
        plus <strong>Log Analytics Reader</strong> on any workspace used for guest heartbeats:
        <pre className="mt-2 overflow-x-auto whitespace-pre-wrap font-mono text-[11px]">{`az ad sp create-for-rbac --name skywatch-reader --role Reader --scopes /subscriptions/<id>
az role assignment create --assignee <appId> --role "Monitoring Reader" --scope /subscriptions/<id>`}</pre>
      </div>
      <Field label="Authentication">
        <Select value={form.auth_method} onChange={set('auth_method')} className="w-full">
          <option value="client_secret">Client secret</option><option value="client_certificate">Client certificate (recommended)</option>
          <option value="managed_identity">Managed identity (Skywatch hosted in Azure)</option>
        </Select>
      </Field>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <Field label="Tenant ID"><Input required value={form.tenant_id ?? ''} onChange={set('tenant_id')} placeholder="00000000-0000-0000-0000-000000000000" /></Field>
        <Field label="Client (application) ID" hint={form.auth_method === 'managed_identity' ? 'Optional: user-assigned identity client ID' : undefined}>
          <Input required={form.auth_method !== 'managed_identity'} value={form.client_id ?? ''} onChange={set('client_id')} />
        </Field>
      </div>
      {form.auth_method === 'client_secret' && <Field label="Client secret"><Input type="password" autoComplete="off" required value={form.client_secret ?? ''} onChange={set('client_secret')} /></Field>}
      {form.auth_method === 'client_certificate' && <Field label="Certificate and private key (PEM)"><Textarea rows={5} required value={form.certificate_pem ?? ''} onChange={set('certificate_pem')} className="font-mono text-[11px]" /></Field>}
      <Field label="Subscription IDs" hint="One per line. Leave empty to monitor every subscription the identity can read.">
        <Textarea rows={2} value={form.subscription_ids ?? ''} onChange={set('subscription_ids')} className="font-mono text-[12px]" />
      </Field>
      <Field label="Log Analytics workspace IDs (optional)" hint="Workspaces receiving Azure Monitor Agent Heartbeat and VM Insights data.">
        <Textarea rows={2} value={form.workspace_ids ?? ''} onChange={set('workspace_ids')} className="font-mono text-[12px]" />
      </Field>
      <Field label="Cloud">
        <Select value={form.cloud} onChange={set('cloud')} className="w-full"><option value="AzurePublic">Azure public</option><option value="AzureUSGovernment">Azure US Government</option><option value="AzureChina">Azure China</option></Select>
      </Field>
    </>
  );
}

function DOFields({ form, set }: F) {
  return (
    <>
      <div className="rounded-md bg-surface-2 p-3 text-xs text-ink-2">
        Create a personal access token with <strong>custom scopes</strong>, read only: <Mono>account:read droplet:read monitoring:read load_balancer:read database:read kubernetes:read block_storage:read actions:read</Mono>.
        Memory and disk usage additionally require the DigitalOcean metrics agent on each Droplet.
      </div>
      <Field label="API token"><Input type="password" autoComplete="off" required value={form.token ?? ''} onChange={set('token')} placeholder="dop_v1_…" /></Field>
    </>
  );
}

function AlibabaFields({ form, set }: F) {
  return (
    <>
      <div className="rounded-md bg-surface-2 p-3 text-xs text-ink-2">
        Create a RAM user for programmatic access and attach <strong>AliyunECSReadOnlyAccess</strong> and <strong>AliyunCloudMonitorReadOnlyAccess</strong> (or the
        narrower custom policy in docs/onboarding/alibaba.md). Guest memory and disk metrics require the CloudMonitor agent.
      </div>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <Field label="AccessKey ID"><Input required value={form.access_key_id ?? ''} onChange={set('access_key_id')} placeholder="LTAI…" /></Field>
        <Field label="AccessKey secret"><Input type="password" autoComplete="off" required value={form.access_key_secret ?? ''} onChange={set('access_key_secret')} /></Field>
      </div>
      <Field label="Regions" hint="Region IDs to monitor, e.g. cn-hongkong ap-southeast-1"><Input required value={form.regions ?? ''} onChange={set('regions')} /></Field>
      <Field label="Account UID (optional)"><Input value={form.account_uid ?? ''} onChange={set('account_uid')} /></Field>
    </>
  );
}
