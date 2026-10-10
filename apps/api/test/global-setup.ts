// Creates a throwaway database, applies db/migrations and exposes its URLs to tests.
// The API under test connects as skywatch_api, the RLS-restricted runtime role.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import pg from 'pg';

const admin = process.env.SKYWATCH_TEST_ADMIN_URL ?? 'postgres://postgres:postgres@127.0.0.1:5432/postgres';
const name = `skywatch_api_test_${Date.now()}`;

export async function setup() {
  const c = new pg.Client({ connectionString: admin });
  await c.connect();
  await c.query(`CREATE DATABASE ${name}`);
  await c.end();
  const u = new URL(admin);
  u.pathname = '/' + name;
  const db = new pg.Client({ connectionString: u.toString() });
  await db.connect();
  // Runtime roles (cluster-wide; idempotent).
  await db.query(readFileSync(join(__dirname, '../../../db/init/00-roles.sql'), 'utf8'));
  const dir = join(__dirname, '../../../db/migrations');
  for (const f of readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()) {
    await db.query(readFileSync(join(dir, f), 'utf8'));
  }
  await db.end();
  const apiUrl = new URL(u.toString());
  apiUrl.username = 'skywatch_api';
  apiUrl.password = 'skywatch_api_dev';
  process.env.TEST_ADMIN_DB_URL = u.toString();
  process.env.SKYWATCH_API_DATABASE_URL = apiUrl.toString();
}

export async function teardown() {
  const c = new pg.Client({ connectionString: admin });
  await c.connect();
  await c.query(`DROP DATABASE IF EXISTS ${name} WITH (FORCE)`);
  await c.end();
}
