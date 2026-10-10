import cookie from '@fastify/cookie';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import Fastify, { type FastifyInstance } from 'fastify';
import { ZodError } from 'zod';
import { checkCsrf, loadPrincipal } from './auth/session.js';
import type { Config } from './config.js';
import type { Db } from './db.js';
import { controlClient, type ControlClient } from './lib/control.js';
import { parseKeyring, type Keyring } from './lib/envelope.js';
import { HttpError } from './lib/errors.js';
import accountRoutes from './routes/accounts.js';
import adminRoutes from './routes/admin.js';
import agentRoutes from './routes/agents.js';
import authRoutes from './routes/auth.js';
import configRoutes from './routes/config.js';
import dashboardRoutes from './routes/dashboard.js';
import incidentRoutes from './routes/incidents.js';
import reportRoutes from './routes/reports.js';
import resourceRoutes from './routes/resources.js';

export interface Deps {
  cfg: Config;
  db: Db;
  keys: Keyring;
  control: ControlClient;
}

declare module 'fastify' {
  interface FastifyInstance {
    deps: Deps;
  }
}

export async function buildApp(cfg: Config, db: Db, overrides: Partial<Deps> = {}): Promise<FastifyInstance> {
  const app = Fastify({
    logger: { level: process.env.LOG_LEVEL ?? (cfg.production ? 'info' : 'warn'), redact: ['req.headers.cookie', 'req.headers["x-csrf-token"]'] },
    trustProxy: cfg.trustProxy,
    bodyLimit: 1 << 20,
  });
  app.decorate('deps', { cfg, db, keys: parseKeyring(cfg.keks), control: controlClient(cfg), ...overrides });

  await app.register(helmet, {
    contentSecurityPolicy: { directives: { defaultSrc: ["'none'"], frameAncestors: ["'none'"] } },
  });
  await app.register(cookie, { secret: process.env.SKYWATCH_COOKIE_SECRET });
  await app.register(rateLimit, { max: 600, timeWindow: '1 minute', keyGenerator: (req) => req.ip });

  app.addHook('onRequest', async (req) => {
    req.principal = await loadPrincipal(db, req);
    checkCsrf(req);
  });

  app.setErrorHandler((err, req, reply) => {
    if (err instanceof HttpError) return reply.status(err.status).send({ error: err.code, message: err.message });
    if (err instanceof ZodError) {
      return reply.status(400).send({
        error: 'validation',
        message: 'Invalid request',
        issues: err.issues.map((i) => ({ path: i.path.join('.'), message: i.message })),
      });
    }
    const e = err as { statusCode?: number; code?: string; message: string };
    if (e.statusCode && e.statusCode < 500) return reply.status(e.statusCode).send({ error: 'request', message: e.message });
    if (e.code === '23505') return reply.status(409).send({ error: 'conflict', message: 'A record with these values already exists' });
    if (e.code === '42501') return reply.status(403).send({ error: 'forbidden', message: 'Not permitted' });
    req.log.error(err);
    return reply.status(500).send({ error: 'internal', message: 'Internal error' });
  });

  app.get('/healthz', async () => {
    await db.query('SELECT 1');
    return { ok: true };
  });

  await app.register(
    async (api) => {
      await api.register(authRoutes);
      await api.register(dashboardRoutes);
      await api.register(resourceRoutes);
      await api.register(incidentRoutes);
      await api.register(configRoutes);
      await api.register(accountRoutes);
      await api.register(agentRoutes);
      await api.register(reportRoutes);
      await api.register(adminRoutes);
    },
    { prefix: '/api/v1' },
  );
  return app;
}
