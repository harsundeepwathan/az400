import { config } from "dotenv";

// Mirrors Next.js precedence for the variables scripts need.
config({ path: ".env.local", quiet: true });
config({ path: ".env", quiet: true });
