const { test, expect } = require('@playwright/test');
const { url, goAndAuth, ADMIN_USER, ADMIN_PASSWORD } = require('./helpers');

// Audiobookshelf OIDC callback is misconfigured (see ISSUE-013).
// Log in with the local admin account instead.
test.describe('Audiobookshelf', () => {
  async function loginAbs(page) {
    await goAndAuth(page, url('audiobooks'));
    // ABS base path is /audiobookshelf
    await page.locator('input[name="username"]').waitFor({ state: 'visible', timeout: 10_000 });
    await page.locator('input[name="username"]').fill(ADMIN_USER);
    await page.locator('input[name="password"]').fill(ADMIN_PASSWORD);
    await page.locator('button[type="submit"]').click();
    await page.waitForURL('**/audiobookshelf/**', { timeout: 20_000 });
  }

  test('library loads after local login', async ({ page }) => {
    await loginAbs(page);
    await expect(page.locator('#__nuxt').first()).toBeVisible({ timeout: 15_000 });
  });

  test('library content area is accessible after login', async ({ page }) => {
    await loginAbs(page);
    await page.waitForTimeout(2000);
    await expect(page.locator('#__nuxt').first()).toBeVisible({ timeout: 15_000 });
    await expect(page).toHaveTitle(/audiobookshelf/i, { timeout: 10_000 });
  });
});
