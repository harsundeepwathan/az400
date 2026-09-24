import { config } from "dotenv";

config({ path: ".env.local", quiet: true });
config({ path: ".env", quiet: true });
process.env.SESSION_SECRET ??= "test-secret-that-is-at-least-32-characters-long";
