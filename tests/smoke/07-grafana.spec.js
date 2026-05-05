const { test, expect } = require('@playwright/test');
const { url, goAndAuth, handleAuthentikIfNeeded } = require('./helpers');

// Grafana has GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN=true so /login redirects straight
// to Authentik OIDC. Use the stored Authentik session (no cleared storage).
test.describe('Grafana', () => {
  test('admin can log in via Authentik OIDC', async ({ page }) => {
    // Grafana auto-redirects to Authentik; goAndAuth handles the login flow
    await goAndAuth(page, url('grafana'));

    // May land on Authentik OIDC due to auto-login redirect
    await handleAuthentikIfNeeded(page);

    // Wait for Grafana to finish the OIDC callback and render the app
    await page.waitForURL(`**${new URL(url('grafana')).hostname}**`, { timeout: 20_000 });
    await page.waitForTimeout(2000);

    await expect(page.locator('[data-testid="data-testid Nav bar"], nav, .page-scrollbar-wrapper, .main-view').first())
      .toBeVisible({ timeout: 15_000 });
  });

  test('dashboards list is accessible', async ({ page }) => {
    await goAndAuth(page, url('grafana'));
    await handleAuthentikIfNeeded(page);
    await page.waitForURL(`**${new URL(url('grafana')).hostname}**`, { timeout: 20_000 });
    await page.waitForTimeout(1500);

    await page.goto(url('grafana') + '/dashboards', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(2000);

    // Grafana dashboards page with provisioned Prometheus/Node Exporter boards
    await expect(page.locator('[data-testid*="dashboard"], ul, [class*="search"]').first())
      .toBeVisible({ timeout: 15_000 });
  });
});
