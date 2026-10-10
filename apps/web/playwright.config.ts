import { defineConfig } from '@playwright/test';

// End-to-end tests run against a running stack (docker compose or local processes)
// seeded with `skywatch seed-demo`. Set SKYWATCH_E2E_URL to target another deployment.
export default defineConfig({
  testDir: './e2e',
  timeout: 30_000,
  retries: 0,
  use: {
    baseURL: process.env.SKYWATCH_E2E_URL ?? 'http://localhost:3000',
    trace: 'retain-on-failure',
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_PATH ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_PATH } : undefined,
  },
  reporter: [['list']],
});
