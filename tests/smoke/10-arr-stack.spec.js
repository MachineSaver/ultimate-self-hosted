const { test, expect } = require('@playwright/test');
const { url, goAndAuth } = require('./helpers');

// All arr-stack apps: Sonarr, Radarr, Lidarr, Prowlarr.
// They use CSS modules so class names include hashes; check by title and known pattern.

for (const [name, subdomain] of [
  ['Sonarr', 'sonarr'],
  ['Radarr', 'radarr'],
  ['Lidarr', 'lidarr'],
  ['Prowlarr', 'prowlarr'],
]) {
  test.describe(name, () => {
    test(`${name} loads and shows main page header`, async ({ page }) => {
      await goAndAuth(page, url(subdomain));
      await page.waitForTimeout(2000);

      // Page title is the app name
      await expect(page).toHaveTitle(new RegExp(name, 'i'), { timeout: 15_000 });

      // PageHeader component is always rendered (CSS module class contains "PageHeader")
      await expect(page.locator('[class*="PageHeader"]').first()).toBeVisible({ timeout: 15_000 });
    });

    test(`${name} settings page is accessible`, async ({ page }) => {
      await goAndAuth(page, url(subdomain) + '/settings');
      await expect(page.locator('[class*="settings"], [class*="Settings"], nav').first())
        .toBeVisible({ timeout: 20_000 });
    });
  });
}

// Prowlarr-specific: indexers list
test.describe('Prowlarr indexers', () => {
  test('indexers page loads', async ({ page }) => {
    await goAndAuth(page, url('prowlarr') + '/indexers');
    await page.waitForTimeout(2000);

    await expect(page).toHaveTitle(/Prowlarr/i, { timeout: 10_000 });
    await expect(page.locator('[class*="PageHeader"]').first()).toBeVisible({ timeout: 15_000 });
  });
});
