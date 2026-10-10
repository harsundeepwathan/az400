import { expect, test, type Page } from '@playwright/test';

const PASSWORD = process.env.SKYWATCH_DEMO_PASSWORD ?? 'skywatch-demo';

async function login(page: Page, email: string) {
  await page.goto('/login');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL('/');
}

test('sign-in rejects a wrong password', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill('admin@demo.local');
  await page.getByLabel('Password').fill('wrong-password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByText('Invalid email or password')).toBeVisible();
});

test('overview shows fleet health and the demo label', async ({ page }) => {
  await login(page, 'admin@demo.local');
  await expect(page.getByText('Demo environment — synthetic data.')).toBeVisible();
  await expect(page.getByText('Monitored resources')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Health by cloud provider' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Active incidents' })).toBeVisible();
});

test('inventory filters by provider and opens a server', async ({ page }) => {
  await login(page, 'admin@demo.local');
  await page.goto('/inventory');
  await page.getByLabel('Provider').selectOption('digitalocean');
  await expect(page).toHaveURL(/provider=digitalocean/);
  const rows = page.locator('tbody tr');
  await expect(rows.first()).toBeVisible();
  await expect(page.getByText('sql-prod-01')).toHaveCount(0);
  await page.getByLabel('Provider').selectOption('');
  await page.getByRole('link', { name: 'sql-prod-01' }).click();
  await expect(page.getByRole('heading', { name: 'Health signals' })).toBeVisible();
  await expect(page.getByText('Power state alone never implies the OS is responsive.')).toBeVisible();
  await page.getByRole('tab', { name: 'Metrics' }).click();
  await expect(page.getByRole('heading', { name: 'CPU utilization' })).toBeVisible();
});

test('missing heartbeat is critical but not a confirmed outage', async ({ page }) => {
  await login(page, 'admin@demo.local');
  await page.goto('/inventory?q=jump-01');
  await page.getByRole('link', { name: 'jump-01' }).click();
  await expect(page.getByText(/host status unconfirmed/).first()).toBeVisible();
  await expect(page.getByText('Host outage is')).toBeVisible();
});

test('operator acknowledges an incident; the timeline records it', async ({ page }) => {
  await login(page, 'operator@demo.local');
  await page.goto('/incidents');
  await page.locator('tbody tr a').first().click();
  await expect(page.getByRole('heading', { name: 'Timeline' })).toBeVisible();
  const ack = page.getByRole('button', { name: 'Acknowledge' });
  if (await ack.count()) {
    await ack.click();
    await expect(ack).toHaveCount(0);
    await expect(page.getByText(/^Acknowledged/).first()).toBeVisible();
  }
  await page.getByLabel('Add a note').fill('e2e: investigating');
  await page.getByRole('button', { name: 'Comment' }).click();
  await expect(page.getByText('e2e: investigating')).toBeVisible();
});

test('viewer has no incident or configuration actions', async ({ page }) => {
  await login(page, 'viewer@demo.local');
  await page.goto('/incidents');
  await page.locator('tbody tr a').first().click();
  await expect(page.getByRole('heading', { name: 'Timeline' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Acknowledge' })).toHaveCount(0);
  await page.goto('/alerts');
  await expect(page.getByRole('button', { name: 'New rule' })).toHaveCount(0);
});

test('organizations are isolated', async ({ page }) => {
  await login(page, 'admin@acme.local');
  await expect(page.getByText('Demo environment')).toHaveCount(0);
  await page.goto('/inventory');
  await expect(page.getByText('No resources match')).toBeVisible();
  const res = await page.request.get('/api/v1/resources?q=sql-prod-01');
  expect((await res.json()).items).toHaveLength(0);
});

test('wallboard renders for large displays', async ({ page }) => {
  await login(page, 'admin@demo.local');
  await page.goto('/wallboard');
  await expect(page.getByRole('heading', { name: 'Active incidents' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Unhealthy hosts' })).toBeVisible();
});
