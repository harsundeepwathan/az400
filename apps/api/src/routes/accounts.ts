// Cloud account onboarding. Credentials are envelope-encrypted on receipt, bound to the
// organization and account id, and never returned by any endpoint.
import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { requirePerm } from '../auth/session.js';
import { withScope } from '../db.js';
import { audit } from '../lib/audit.js';
import { cloudAccountAad, seal } from '../lib/envelope.js';
import { badRequest, notFound } from '../lib/errors.js';
import { body, idParams, params } from '../lib/http.js';

const guid = z.string().regex(/^[0-9a-fA-F-]{36}$/, 'Must be a GUID');

const azure = z.object({
  provider: z.literal('azure'),
  name: z.string().trim().min(1).max(200),
  auth_method: z.enum(['client_secret', 'client_certificate', 'managed_identity']),
  tenant_id: guid,
  client_id: guid.optional(),
  client_secret: z.string().min(1).max(500).optional(),
  certificate_pem: z.string().min(1).max(20000).optional(),
  subscription_ids: z.array(guid).max(200).default([]),
  log_analytics_workspace_ids: z.array(guid).max(20).default([]),
  cloud: z.enum(['AzurePublic', 'AzureUSGovernment', 'AzureChina']).default('AzurePublic'),
}).superRefine((a, ctx) => {
  if (a.auth_method === 'client_secret' && (!a.client_id || !a.client_secret)) ctx.addIssue({ code: 'custom', message: 'client_id and client_secret are required', path: ['client_secret'] });
  if (a.auth_method === 'client_certificate' && (!a.client_id || !a.certificate_pem)) ctx.addIssue({ code: 'custom', message: 'client_id and certificate_pem are required', path: ['certificate_pem'] });
});

const digitalocean = z.object({
  provider: z.literal('digitalocean'),
  name: z.string().trim().min(1).max(200),
  token: z.string().regex(/^dop_v1_[a-f0-9]{64}$/, 'Expected a DigitalOcean personal access token (dop_v1_…)'),
});

const alibaba = z.object({
  provider: z.literal('alibaba'),
  name: z.string().trim().min(1).max(200),
  access_key_id: z.string().regex(/^LTAI[A-Za-z0-9]{12,30}$/, 'Expected a RAM AccessKey ID (LTAI…)'),
  access_key_secret: z.string().min(20).max(100),
  security_token: z.string().max(4000).optional(),
  account_uid: z.string().regex(/^\d{10,20}$/).optional(),
  regions: z.array(z.string().regex(/^[a-z]{2}-[a-z0-9-]+$/)).min(1).max(30),
});

const createSchema = z.discriminatedUnion('provider', [azure as any, digitalocean, alibaba]) as unknown as z.ZodType<
  z.infer<typeof azure> | z.infer<typeof digitalocean> | z.infer<typeof alibaba>
>;

function split(a: z.infer<typeof createSchema>) {
  switch (a.provider) {
    case 'azure':
      return {
        authMethod: a.auth_method,
        externalId: a.tenant_id,
        hint: a.client_id ? `client ${a.client_id}` : 'managed identity',
        secret: { tenant_id: a.tenant_id, client_id: a.client_id ?? '', client_secret: a.client_secret ?? '', certificate_pem: a.certificate_pem ?? '' },
        config: { tenant_id: a.tenant_id, subscription_ids: a.subscription_ids, log_analytics_workspace_ids: a.log_analytics_workspace_ids, cloud: a.cloud },
      };
    case 'digitalocean':
      return { authMethod: 'token', externalId: null, hint: `token …${a.token.slice(-4)}`, secret: { token: a.token }, config: {} };
    case 'alibaba':
      return {
        authMethod: a.security_token ? 'sts' : 'access_key',
        externalId: a.account_uid ?? null,
        hint: `AccessKey ${a.access_key_id.slice(0, 8)}…`,
        secret: { access_key_id: a.access_key_id, access_key_secret: a.access_key_secret, security_token: a.security_token ?? '' },
        config: { regions: a.regions },
      };
  }
}

const PUBLIC_COLUMNS = `id, provider, name, external_id, auth_method, credential_hint, config, status, status_reason, capabilities,
  permission_report, last_validated_at, last_discovery_at, last_success_at, throttle_events, last_throttled_at, created_at, updated_at`;

const routes: FastifyPluginAsync = async (app) => {
  const { db, keys, control } = app.deps;

  app.get('/accounts', async (req) => {
    const s = requirePerm(req, 'read');
    return withScope(db, s, async (tx) => (await tx.query(`SELECT ${PUBLIC_COLUMNS.split(',').map((c) => 'a.' + c.trim()).join(', ')},
        (SELECT count(*)::int FROM resources r WHERE r.cloud_account_id=a.id AND r.deleted_at IS NULL) AS resource_count,
        (SELECT jsonb_agg(jsonb_build_object('kind', kind, 'last_status', last_status, 'last_error', last_error, 'last_finished_at', last_finished_at,
            'next_run_at', next_run_at, 'consecutive_failures', consecutive_failures)) FROM collection_jobs j WHERE j.cloud_account_id=a.id) AS jobs
      FROM cloud_accounts a ORDER BY a.provider, a.name`)).rows);
  });

  app.get('/accounts/:id', async (req) => {
    const s = requirePerm(req, 'read');
    const { id } = params(req, idParams);
    return withScope(db, s, async (tx) => {
      const a = (await tx.query(`SELECT ${PUBLIC_COLUMNS} FROM cloud_accounts WHERE id=$1`, [id])).rows[0];
      if (!a) throw notFound('Account not found');
      const runs = (await tx.query(`SELECT kind, started_at, finished_at, status, error, api_calls, throttled_calls, items
        FROM collector_runs WHERE cloud_account_id=$1 ORDER BY started_at DESC LIMIT 50`, [id])).rows;
      return { ...a, runs };
    });
  });

  // Step 2: store credentials (encrypted) — the account starts in "pending".
  app.post('/accounts', async (req) => {
    const s = requirePerm(req, 'accounts.manage');
    const a = body(req, createSchema);
    const p = split(a);
    const id = crypto.randomUUID();
    const blob = seal(keys, JSON.stringify(p.secret), cloudAccountAad(s.orgId, id));
    return withScope(db, s, async (tx) => {
      const { rows } = await tx.query(`INSERT INTO cloud_accounts(id, org_id, provider, name, external_id, auth_method, credential_ciphertext,
          credential_key_id, credential_hint, config, status, created_by)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'pending',$11) RETURNING ${PUBLIC_COLUMNS}`,
        [id, s.orgId, a.provider, a.name, p.externalId, p.authMethod, blob, keys.activeId, p.hint, p.config, s.userId]);
      await audit(tx, { ...s, action: 'cloud_account.created', targetType: 'cloud_account', targetId: id, details: { provider: a.provider, name: a.name }, ip: req.ip });
      return rows[0];
    });
  });

  // Rotate credentials or edit non-secret settings.
  app.patch('/accounts/:id', async (req) => {
    const s = requirePerm(req, 'accounts.manage');
    const { id } = params(req, idParams);
    const b = body(req, z.object({
      name: z.string().trim().min(1).max(200).optional(),
      credentials: z.record(z.string(), z.unknown()).optional(),
      excluded_resource_ids: z.array(z.string().max(500)).max(10000).optional(),
    }));
    return withScope(db, s, async (tx) => {
      const cur = (await tx.query(`SELECT provider, name, auth_method, config FROM cloud_accounts WHERE id=$1 FOR UPDATE`, [id])).rows[0];
      if (!cur) throw notFound();
      if (cur.auth_method === 'demo') throw badRequest('Demo accounts cannot be modified');
      if (b.credentials) {
        const parsed = createSchema.parse({ ...cur.config, ...b.credentials, provider: cur.provider, name: b.name ?? cur.name,
          auth_method: (b.credentials as any).auth_method ?? (cur.provider === 'azure' ? cur.auth_method : undefined) });
        const p = split(parsed);
        await tx.query(`UPDATE cloud_accounts SET credential_ciphertext=$2, credential_key_id=$3, credential_hint=$4, auth_method=$5,
            config = config || $6, status='pending', status_reason='Credentials rotated: validate to resume', updated_at=now() WHERE id=$1`,
          [id, seal(keys, JSON.stringify(p.secret), cloudAccountAad(s.orgId, id)), keys.activeId, p.hint, p.authMethod, p.config]);
      }
      if (b.name) await tx.query(`UPDATE cloud_accounts SET name=$2, updated_at=now() WHERE id=$1`, [id, b.name]);
      if (b.excluded_resource_ids) {
        await tx.query(`UPDATE cloud_accounts SET config = config || jsonb_build_object('excluded_resource_ids', $2::jsonb) WHERE id=$1`,
          [id, JSON.stringify(b.excluded_resource_ids)]);
      }
      await audit(tx, { ...s, action: b.credentials ? 'cloud_account.credentials_rotated' : 'cloud_account.updated', targetType: 'cloud_account', targetId: id,
        details: { name: b.name, excluded: b.excluded_resource_ids?.length }, ip: req.ip });
      return (await tx.query(`SELECT ${PUBLIC_COLUMNS} FROM cloud_accounts WHERE id=$1`, [id])).rows[0];
    });
  });

  // Step 3: validate connectivity and permissions (runs the real provider adapter).
  app.post('/accounts/:id/validate', async (req) => {
    const s = requirePerm(req, 'accounts.manage');
    const { id } = params(req, idParams);
    await withScope(db, s, async (tx) => {
      if (!(await tx.query(`SELECT 1 FROM cloud_accounts WHERE id=$1`, [id])).rows[0]) throw notFound();
      await audit(tx, { ...s, action: 'cloud_account.validated', targetType: 'cloud_account', targetId: id, ip: req.ip });
    });
    return control.validate(s.orgId, id);
  });

  // Step 4: preview discoverable resources before activation.
  app.post('/accounts/:id/discover', async (req) => {
    const s = requirePerm(req, 'accounts.manage');
    const { id } = params(req, idParams);
    await withScope(db, s, async (tx) => {
      if (!(await tx.query(`SELECT 1 FROM cloud_accounts WHERE id=$1`, [id])).rows[0]) throw notFound();
    });
    return control.discover(s.orgId, id);
  });

  // Step 7: activate monitoring. Collection jobs are created by the collector within a minute.
  app.post('/accounts/:id/activate', async (req) => {
    const s = requirePerm(req, 'accounts.manage');
    const { id } = params(req, idParams);
    return withScope(db, s, async (tx) => {
      const a = (await tx.query(`SELECT status, last_validated_at, permission_report FROM cloud_accounts WHERE id=$1 FOR UPDATE`, [id])).rows[0];
      if (!a) throw notFound();
      if (!a.last_validated_at || a.permission_report?.ok !== true) throw badRequest('Validate the account successfully before activating it');
      await tx.query(`UPDATE cloud_accounts SET status='active', status_reason=NULL, updated_at=now() WHERE id=$1`, [id]);
      await audit(tx, { ...s, action: 'cloud_account.activated', targetType: 'cloud_account', targetId: id, ip: req.ip });
      return { ok: true };
    });
  });

  app.post('/accounts/:id/disable', async (req) => {
    const s = requirePerm(req, 'accounts.manage');
    const { id } = params(req, idParams);
    return withScope(db, s, async (tx) => {
      const { rowCount } = await tx.query(`UPDATE cloud_accounts SET status='disabled', status_reason='Disabled by administrator', updated_at=now() WHERE id=$1`, [id]);
      if (!rowCount) throw notFound();
      await audit(tx, { ...s, action: 'cloud_account.disabled', targetType: 'cloud_account', targetId: id, ip: req.ip });
      return { ok: true };
    });
  });

  app.delete('/accounts/:id', async (req) => {
    const s = requirePerm(req, 'accounts.manage');
    const { id } = params(req, idParams);
    return withScope(db, s, async (tx) => {
      const { rowCount } = await tx.query(`DELETE FROM cloud_accounts WHERE id=$1`, [id]);
      if (!rowCount) throw notFound();
      await audit(tx, { ...s, action: 'cloud_account.deleted', targetType: 'cloud_account', targetId: id, ip: req.ip });
      return { ok: true };
    });
  });

  app.get('/providers/capabilities', async (req) => {
    requirePerm(req, 'read');
    return control.providers();
  });
};

export default routes;
