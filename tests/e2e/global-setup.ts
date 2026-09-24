import { execSync } from "node:child_process";

/** Applies migrations and (re)creates the demo account before the suite runs. */
export default function globalSetup() {
  execSync("npm run db:migrate && npm run db:seed", { stdio: "inherit" });
}
