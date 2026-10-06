import Anthropic from "@anthropic-ai/sdk";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createApp } from "./app.js";
import { appleKeys } from "./auth.js";
import { loadConfig } from "./config.js";
import { createPool, migrate } from "./db.js";
import { jsonLogger } from "./http.js";

// Entry point. See README for the environment variables.
const config = loadConfig(process.env, (path) => readFileSync(path));
const db = createPool(config.databaseUrl);
const migrations = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "migrations");
const applied = await migrate(db, migrations);
if (applied.length) jsonLogger.info("migrations_applied", { applied });
if (!config.appleRootCertificate) jsonLogger.error("purchase_verification_disabled", { reason: "APPLE_ROOT_CA_PATH not set" });

const server = createApp({ config, db, claude: new Anthropic(), appleKeys: appleKeys(), log: jsonLogger });
server.listen(config.port, () => jsonLogger.info("listening", { port: config.port }));

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => {
    server.close(() => void db.end().then(() => process.exit(0)));
  });
}
