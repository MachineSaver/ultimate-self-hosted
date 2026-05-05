const { test, expect } = require('@playwright/test');
const { url } = require('./helpers');

test.describe('Authentik', () => {
  test('admin panel loads and lists users', async ({ page }) => {
    await page.goto(url('auth') + '/if/admin/', { waitUntil: 'networkidle', timeout: 30_000 });

    // Admin panel should show the Authentik UI
    await expect(page).toHaveTitle(/Authentik/i, { timeout: 15_000 });

    // Sidebar navigation is visible
    await expect(page.locator('nav, [role="navigation"]').first()).toBeVisible();
  });

  test('users list is accessible', async ({ page }) => {
    await page.goto(url('auth') + '/if/admin/#/identity/users', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(3000);

    // Table or list of users should appear
    const userTable = page.locator('table, ak-user-list, .pf-c-table');
    await expect(userTable.first()).toBeVisible({ timeout: 15_000 });
  });
});
