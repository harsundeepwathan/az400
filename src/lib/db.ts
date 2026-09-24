import "server-only";
import { Pool, type PoolClient, type QueryResultRow } from "pg";
import { env } from "./env";

declare global {
  var __jobpilotPool: Pool | undefined;
}

function pool(): Pool {
  if (!globalThis.__jobpilotPool) {
    globalThis.__jobpilotPool = new Pool({
      connectionString: env().DATABASE_URL,
      max: 10,
      idleTimeoutMillis: 30_000,
    });
  }
  return globalThis.__jobpilotPool;
}

export type Db = {
  query<T extends QueryResultRow = QueryResultRow>(sql: string, params?: unknown[]): Promise<T[]>;
  one<T extends QueryResultRow = QueryResultRow>(sql: string, params?: unknown[]): Promise<T | null>;
};

/** Serialises queries on one client so callers may safely use Promise.all inside a transaction. */
function wrap(client: PoolClient): Db {
  let queue: Promise<unknown> = Promise.resolve();
  const run = <T,>(sql: string, params?: unknown[]) => {
    const next = queue.then(() => client.query(sql, params));
    queue = next.catch(() => undefined);
    return next as Promise<{ rows: T[] }>;
  };
  return {
    async query(sql, params) {
      return (await run(sql, params)).rows as never;
    },
    async one(sql, params) {
      return ((await run(sql, params)).rows[0] ?? null) as never;
    },
  };
}

/**
 * Runs `fn` in a transaction as the `authenticated` role with the user's id in
 * the JWT claims, exactly as Supabase's PostgREST does. Row-level security
 * therefore applies to every statement, in addition to the explicit
 * `user_id` filters used throughout the data layer (defence in depth).
 */
export async function withUser<T>(userId: string, fn: (db: Db) => Promise<T>): Promise<T> {
  if (!/^[0-9a-f-]{36}$/i.test(userId)) throw new Error("Invalid user id");
  const client = await pool().connect();
  try {
    await client.query("begin");
    await client.query("set local role authenticated");
    await client.query(
      "select set_config('request.jwt.claims', $1, true), set_config('request.jwt.claim.sub', $2, true)",
      [JSON.stringify({ sub: userId, role: "authenticated" }), userId],
    );
    const result = await fn(wrap(client));
    await client.query("commit");
    return result;
  } catch (error) {
    await client.query("rollback").catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}

/**
 * Privileged access that bypasses RLS. Only for operations that cannot run as
 * the user: local-mode sign-up/sign-in and account deletion. Never pass
 * user-controlled SQL here.
 */
export async function withAdmin<T>(fn: (db: Db) => Promise<T>): Promise<T> {
  const client = await pool().connect();
  try {
    await client.query("begin");
    const result = await fn(wrap(client));
    await client.query("commit");
    return result;
  } catch (error) {
    await client.query("rollback").catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}
