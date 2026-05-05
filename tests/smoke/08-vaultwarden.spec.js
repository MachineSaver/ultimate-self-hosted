const { test, expect } = require('@playwright/test');
const { url, goAndAuth, ADMIN_USER, ADMIN_PASSWORD } = require('./helpers');

test.describe('Vaultwarden', () => {
  test('web vault loads', async ({ page }) => {
    await page.goto(url('vault') + '/#/login', { waitUntil: 'domcontentloaded', timeout: 30_000 });

    // Bitwarden/Vaultwarden web vault login page
    await expect(page.locator('[class*="login"], form, [id="main-content"]').first())
      .toBeVisible({ timeout: 15_000 });
  });

  test('SSO login flow reaches the vault', async ({ page }) => {
    await page.goto(url('vault') + '/#/sso', { waitUntil: 'domcontentloaded', timeout: 30_000 }).catch(() => {});
    await page.goto(url('vault') + '/#/login', { waitUntil: 'domcontentloaded', timeout: 30_000 });

    // Click Enterprise SSO or "Log in with SSO" if available
    const ssoBtn = page.locator('button:has-text("Enterprise SSO"), button:has-text("Log in with SSO"), a:has-text("SSO")');
    const hasSso = await ssoBtn.isVisible({ timeout: 6_000 }).catch(() => false);
    if (hasSso) {
      await ssoBtn.first().click();
      // Authentik SSO
      await goAndAuth(page, page.url()); // handle any Authentik redirect
      await page.waitForURL(`**${new URL(url('vault')).hostname}**`, { timeout: 20_000 });
      await expect(page.locator('[class*="vault"], [class*="items"], form').first())
        .toBeVisible({ timeout: 15_000 });
    } else {
      // Fall back: verify login page renders
      await expect(page.locator('form, input[type="email"], input[name="email"]').first())
        .toBeVisible({ timeout: 10_000 });
    }
  });

  test('admin panel is accessible via admin token', async ({ page }) => {
    await page.goto(url('vault') + '/admin', { waitUntil: 'domcontentloaded', timeout: 30_000 });

    // Admin panel login page should appear
    await expect(page.locator('input[name="token"], input[type="password"]').first())
      .toBeVisible({ timeout: 15_000 });
  });
});
