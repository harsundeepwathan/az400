import pg from 'pg';

export type Db = pg.Pool;
export type Tx = pg.PoolClient;

export function createPool(url: string): Db {
  const pool = new pg.Pool({ connectionString: url, max: 20, application_name: 'skywatch-api' });
  pool.on('error', (err) => console.error('pg pool error', err));
  return pool;
}

export interface Scope {
  orgId: string | null;
  userId: string | null;
}

/**
 * Runs fn in a transaction scoped to a tenant. The API database role is subject to
 * row-level security; app.org_id / app.user_id are set transaction-locally so a
 * connection returned to the pool never carries another request's tenant.
 */
export async function withScope<T>(db: Db, scope: Scope, fn: (tx: Tx) => Promise<T>): Promise<T> {
  const client = await db.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.org_id', $1, true), set_config('app.user_id', $2, true)", [
      scope.orgId ?? '',
      scope.userId ?? '',
    ]);
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw err;
  } finally {
    client.release();
  }
}
