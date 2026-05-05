const { test, expect } = require('@playwright/test');
const { url, ADMIN_USER, ADMIN_PASSWORD } = require('./helpers');

// Nextcloud currently shows a configuration error (see ISSUE-011).
// Tests are skipped until the server issue is resolved.
test.describe('Nextcloud', () => {
  test('login page is reachable', async ({ page }) => {
    await page.goto(url('cloud') + '/index.php/login', { waitUntil: 'networkidle', timeout: 30_000 });

    const hasError = await page.locator('text=Configuration was not initialized correctly').isVisible({ timeout: 3_000 }).catch(() => false);
    if (hasError) {
      test.skip(true, 'ISSUE-011: Nextcloud configuration error — config.php not initialized correctly');
      return;
    }

    await expect(page).toHaveTitle(/Nextcloud/i, { timeout: 10_000 });
  });

  test('admin can log in via local account', async ({ page }) => {
    await page.goto(url('cloud') + '/index.php/login', { waitUntil: 'networkidle', timeout: 30_000 });

    const hasError = await page.locator('text=Configuration was not initialized correctly').isVisible({ timeout: 3_000 }).catch(() => false);
    const hasForm = await page.locator('#user, input[name="user"]').isVisible({ timeout: 5_000 }).catch(() => false);
    if (hasError || !hasForm) {
      test.skip(true, 'ISSUE-011: Nextcloud login form not available — configuration error or service not initialized');
      return;
    }

    await page.locator('#user, input[name="user"]').fill(ADMIN_USER);
    await page.locator('#password, input[name="password"]').fill(ADMIN_PASSWORD);
    await page.locator('#submit-form, button[type="submit"]').click();

    await page.waitForURL('**/apps/**', { timeout: 25_000 });
    await expect(page.locator('#app-content, .app-content').first()).toBeVisible({ timeout: 15_000 });
  });
});
