const { test, expect } = require('@playwright/test');
const { url, goAndAuth, ADMIN_USER, ADMIN_PASSWORD } = require('./helpers');

// qBittorrent has its own login on top of Traefik forward_auth.
// Credentials are set from ADMIN_USER/ADMIN_PASSWORD during install.
test.describe('qBittorrent', () => {
  async function loginQBit(page) {
    await goAndAuth(page, url('qbit'));
    const loginForm = page.locator('#loginform');
    const hasLogin = await loginForm.isVisible({ timeout: 5_000 }).catch(() => false);
    if (hasLogin) {
      await page.locator('#username').fill(ADMIN_USER);
      await page.locator('#password').fill(ADMIN_PASSWORD);
      await page.locator('#loginButton').click();
      await page.waitForTimeout(2000);
    }
  }

  test('web UI loads and shows the main desktop', async ({ page }) => {
    await loginQBit(page);
    await expect(page.locator('#desktop, #desktopNavbar').first()).toBeVisible({ timeout: 15_000 });
  });

  test('desktop navbar is visible and has transfer links', async ({ page }) => {
    await loginQBit(page);
    await expect(page.locator('#desktopNavbar, #desktopHeader').first()).toBeVisible({ timeout: 15_000 });
    // Transfer action links exist in the navbar
    await expect(page.locator('#uploadLink, #downloadLink').first()).toBeVisible({ timeout: 10_000 });
  });
});
