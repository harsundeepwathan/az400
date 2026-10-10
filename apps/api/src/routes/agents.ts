import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';
import { requirePerm } from '../auth/session.js';
import { withScope } from '../db.js';
import { audit } from '../lib/audit.js';
import { notFound } from '../lib/errors.js';
import { body, idParams, params } from '../lib/http.js';
import { newEnrollmentToken, sha256 } from '../lib/tokens.js';

const routes: FastifyPluginAsync = async (app) => {
  const { db, cfg } = app.deps;

  app.get('/agents', async (req) => {
    const s = requirePerm(req, 'read');
    return withScope(db, s, async (tx) => (await tx.query(`SELECT g.id, g.hostname, g.os_type, g.os_name, g.os_version, g.arch, g.agent_version,
        g.status, g.enrolled_at, g.last_heartbeat_at, g.last_heartbeat_latency_ms, g.last_queue_depth, g.last_dropped_batches,
        g.collector_errors, g.secret_rotated_at, g.last_ip, r.id AS resource_id, r.name AS resource_name, r.provider, r.operational_state
      FROM agents g LEFT JOIN resources r ON r.id = g.resource_id ORDER BY (g.status='active') DESC, g.hostname`)).rows);
  });

  app.post('/agents/:id/revoke', async (req) => {
    const s = requirePerm(req, 'agents.manage');
    const { id } = params(req, idParams);
    return withScope(db, s, async (tx) => {
      const { rowCount } = await tx.query(`UPDATE agents SET status='revoked' WHERE id=$1 AND status='active'`, [id]);
      if (!rowCount) throw notFound('Active agent not found');
      await audit(tx, { ...s, action: 'agent.revoked', targetType: 'agent', targetId: id, ip: req.ip });
      return { ok: true };
    });
  });

  app.get('/agents/enrollment-tokens', async (req) => {
    const s = requirePerm(req, 'agents.manage');
    return withScope(db, s, async (tx) => (await tx.query(`SELECT t.id, t.token_prefix, t.description, t.max_uses, t.uses, t.expires_at, t.revoked_at,
        t.created_at, u.display_name AS created_by_name FROM agent_enrollment_tokens t LEFT JOIN users u ON u.id = t.created_by
      ORDER BY t.created_at DESC LIMIT 100`)).rows);
  });

  // The token is returned exactly once; only its SHA-256 is stored.
  app.post('/agents/enrollment-tokens', async (req) => {
    const s = requirePerm(req, 'agents.manage');
    const b = body(req, z.object({
      description: z.string().max(200).default(''),
      max_uses: z.number().int().min(1).max(10000).default(1),
      ttl_hours: z.number().int().min(1).max(24 * 30).default(24),
    }));
    const token = newEnrollmentToken();
    return withScope(db, s, async (tx) => {
      const { rows } = await tx.query(`INSERT INTO agent_enrollment_tokens(org_id, token_hash, token_prefix, description, max_uses, expires_at, created_by)
        VALUES ($1,$2,$3,$4,$5, now() + make_interval(hours => $6), $7) RETURNING id, expires_at, max_uses`,
        [s.orgId, sha256(token), token.slice(0, 10), b.description, b.max_uses, b.ttl_hours, s.userId]);
      await audit(tx, { ...s, action: 'enrollment_token.created', targetType: 'enrollment_token', targetId: rows[0].id,
        details: { description: b.description, max_uses: b.max_uses, ttl_hours: b.ttl_hours }, ip: req.ip });
      const server = cfg.ingestPublicUrl;
      return {
        ...rows[0],
        token,
        install: {
          linux: `sudo SKYWATCH_SERVER=${server} SKYWATCH_ENROLLMENT_TOKEN=${token} ./install.sh ./skywatch-agent`,
          windows: `$env:SKYWATCH_ENROLLMENT_TOKEN='${token}'; .\\install.ps1 -Server ${server} -Binary .\\skywatch-agent.exe`,
        },
      };
    });
  });

  app.delete('/agents/enrollment-tokens/:id', async (req) => {
    const s = requirePerm(req, 'agents.manage');
    const { id } = params(req, idParams);
    return withScope(db, s, async (tx) => {
      const { rowCount } = await tx.query(`UPDATE agent_enrollment_tokens SET revoked_at=now() WHERE id=$1 AND revoked_at IS NULL`, [id]);
      if (!rowCount) throw notFound();
      await audit(tx, { ...s, action: 'enrollment_token.revoked', targetType: 'enrollment_token', targetId: id, ip: req.ip });
      return { ok: true };
    });
  });
};

export default routes;
