import "./load-env";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { Client } from "pg";

const root = path.resolve(__dirname, "..");
const migrationsDir = path.join(root, "supabase", "migrations");

async function main() {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not set. Copy .env.example to .env.local first.");
  const localMode = (process.env.AUTH_MODE ?? "local") === "local";
  const reset = process.argv.includes("--reset");

  const client = new Client({ connectionString: url });
  await client.connect();
  try {
    if (reset) {
      if (!localMode) throw new Error("--reset is only allowed when AUTH_MODE=local.");
      await client.query(`
        drop schema if exists public cascade;
        create schema public;
        grant usage on schema public to public;
        drop schema if exists jobpilot_meta cascade;
        drop table if exists auth.users cascade;
      `);
      console.log("Local database reset.");
    }

    if (localMode) {
      await client.query(await readFile(path.join(root, "db", "local-bootstrap.sql"), "utf8"));
      await client.query("grant usage on schema public to anon, authenticated, service_role");
    }

    await client.query(`
      create schema if not exists jobpilot_meta;
      create table if not exists jobpilot_meta.migrations (
        name text primary key,
        applied_at timestamptz not null default now()
      );
    `);

    const applied = new Set(
      (await client.query<{ name: string }>("select name from jobpilot_meta.migrations")).rows.map((r) => r.name),
    );
    const files = (await readdir(migrationsDir)).filter((f) => f.endsWith(".sql")).sort();
    let count = 0;
    for (const file of files) {
      if (applied.has(file)) continue;
      const sql = await readFile(path.join(migrationsDir, file), "utf8");
      await client.query("begin");
      try {
        await client.query(sql);
        await client.query("insert into jobpilot_meta.migrations (name) values ($1)", [file]);
        await client.query("commit");
        console.log(`Applied ${file}`);
        count++;
      } catch (error) {
        await client.query("rollback");
        throw new Error(`Migration ${file} failed: ${(error as Error).message}`);
      }
    }
    console.log(count === 0 ? "Database is up to date." : `Applied ${count} migration(s).`);
  } finally {
    await client.end();
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
