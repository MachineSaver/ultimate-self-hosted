const { test, expect } = require('@playwright/test');
const { url, goAndAuth, ADMIN_USER, ADMIN_PASSWORD } = require('./helpers');

// WireGuard Easy (wg-easy v15) has its own login on top of Traefik forward_auth.
// Credentials are set from ADMIN_USER / ADMIN_PASSWORD (INIT_USERNAME/INIT_PASSWORD).
test.describe('WireGuard Easy', () => {
  async function loginWireGuard(page) {
    await goAndAuth(page, url('vpn'));
    const loginCard = page.locator('input[placeholder="Username"], input[placeholder="Password"]').first();
    const hasLogin = await loginCard.isVisible({ timeout: 5_000 }).catch(() => false);
    if (hasLogin) {
      await page.locator('input[placeholder="Username"]').fill(ADMIN_USER);
      await page.locator('input[placeholder="Password"]').fill(ADMIN_PASSWORD);
      await page.locator('button:has-text("Sign In")').click();
      await page.waitForTimeout(2000);
    }
  }

  test('VPN management page loads after login', async ({ page }) => {
    await loginWireGuard(page);
    // wg-easy Nuxt app renders into #__nuxt after login
    await expect(page.locator('#__nuxt, main, [id="__nuxt"]').first()).toBeVisible({ timeout: 15_000 });
    // Should NOT still be showing the login card
    await expect(page.locator('input[placeholder="Username"]')).not.toBeVisible({ timeout: 5_000 });
  });

  test('clients list area is visible', async ({ page }) => {
    await loginWireGuard(page);
    await page.waitForTimeout(2000);

    // After login the Nuxt app renders the VPN client management UI
    await expect(page.locator('#__nuxt').first()).toBeVisible({ timeout: 15_000 });
    // The page has content beyond just the login card
    const bodyText = await page.locator('body').innerText().catch(() => '');
    expect(bodyText.length, 'Page should have rendered content after login').toBeGreaterThan(50);
  });
});
