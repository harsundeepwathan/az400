import pg from "pg";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

export type Db = pg.Pool;
export type Queryable = pg.Pool | pg.PoolClient;

export function createPool(connectionString: string, options: pg.PoolConfig = {}): Db {
  // A small pool is plenty for 10k users; Postgres connection count is the scarce resource.
  return new pg.Pool({ connectionString, max: 10, idleTimeoutMillis: 30_000, ...options });
}

/** Runs `fn` in a transaction, rolling back on any error. */
export async function transaction<T>(db: Db, fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await db.connect();
  try {
    await client.query("begin");
    const result = await fn(client);
    await client.query("commit");
    return result;
  } catch (error) {
    await client.query("rollback").catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

/**
 * Applies `migrations/*.sql` in name order, each once, each in its own
 * transaction. An advisory lock keeps two instances from migrating at once.
 */
export async function migrate(db: Db, directory: string): Promise<string[]> {
  const files = (await readdir(directory)).filter((name) => name.endsWith(".sql")).sort();
  const applied: string[] = [];
  await transaction(db, async (client) => {
    await client.query("select pg_advisory_xact_lock(724501)");
    await client.query(`create table if not exists schema_migrations (
      version text primary key,
      applied_at timestamptz not null default now()
    )`);
    const done = new Set((await client.query<{ version: string }>("select version from schema_migrations")).rows.map((r) => r.version));
    for (const file of files) {
      if (done.has(file)) continue;
      await client.query(await readFile(join(directory, file), "utf8"));
      await client.query("insert into schema_migrations (version) values ($1)", [file]);
      applied.push(file);
    }
  });
  return applied;
}
