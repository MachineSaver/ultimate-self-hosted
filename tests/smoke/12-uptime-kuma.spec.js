const { test, expect } = require('@playwright/test');
const { url, goAndAuth, ADMIN_USER, ADMIN_PASSWORD } = require('./helpers');

test.describe('Uptime Kuma', () => {
  test('login page loads after forward auth', async ({ page }) => {
    await goAndAuth(page, url('uptime'));

    // Uptime Kuma 2.x has its own login on top of the Authentik forward_auth layer
    await expect(page.locator('#loginUsername, input[autocomplete="username"], form').first())
      .toBeVisible({ timeout: 20_000 });
  });

  test('admin can log in and see monitors', async ({ page }) => {
    await goAndAuth(page, url('uptime'));

    // Login with local credentials
    const usernameField = page.locator('#loginUsername, input[autocomplete="username"]');
    await usernameField.fill(ADMIN_USER, { timeout: 10_000 });
    await page.locator('#loginPassword, input[type="password"]').fill(ADMIN_PASSWORD);
    await page.locator('button[type="submit"], button:has-text("Login"), .btn-primary').click();

    // After login, the monitors dashboard should appear
    await page.waitForURL('**', { timeout: 20_000 });
    await expect(page.locator('[class*="monitor"], [class*="heartbeat"], #main').first())
      .toBeVisible({ timeout: 20_000 });
  });
});
