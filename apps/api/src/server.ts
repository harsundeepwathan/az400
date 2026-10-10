import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { createPool } from './db.js';

const cfg = loadConfig();
const db = createPool(cfg.databaseUrl);
const app = await buildApp(cfg, db);
await app.listen({ port: cfg.port, host: cfg.host });
for (const sig of ['SIGINT', 'SIGTERM'] as const) {
  process.on(sig, async () => {
    await app.close();
    await db.end();
    process.exit(0);
  });
}
