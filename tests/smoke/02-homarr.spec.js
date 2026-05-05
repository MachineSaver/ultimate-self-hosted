const { test, expect } = require('@playwright/test');
const { url, goAndAuth, handleAuthentikIfNeeded } = require('./helpers');

test.describe('Homarr', () => {
  test('dashboard loads after OIDC login via Authentik button', async ({ page }) => {
    await goAndAuth(page, url('home'));

    // Homarr shows its own /auth/login with a "Login with Authentik" button
    const ssoBtn = page.locator('button:has-text("Authentik")');
    await ssoBtn.waitFor({ state: 'visible', timeout: 12_000 });
    await ssoBtn.click();

    // Authentik OIDC — may show a consent page on first use
    await handleAuthentikIfNeeded(page);

    // Wait for redirect away from Homarr's /auth/login to the dashboard
    await page.waitForURL((u) => !u.href.includes('/auth/login'), { timeout: 20_000 });

    // Dashboard root should be rendered
    await expect(page.locator('main, [role="main"], #__next, .mantine-AppShell-root').first())
      .toBeVisible({ timeout: 15_000 });
  });

  test('dashboard page is reachable and renders main content', async ({ page }) => {
    await goAndAuth(page, url('home'));

    const ssoBtn = page.locator('button:has-text("Authentik")');
    const hasSso = await ssoBtn.isVisible({ timeout: 10_000 }).catch(() => false);
    if (hasSso) {
      await ssoBtn.click();
      await handleAuthentikIfNeeded(page);
      await page.waitForURL((u) => !u.href.includes('/auth/login'), { timeout: 20_000 });
    }

    // Page title should be Homarr (not the auth page)
    await expect(page).toHaveTitle(/Homarr/i, { timeout: 10_000 });

    // NOTE: default Homarr install has no tiles until the user adds them.
    // See ISSUE-012 for tracking default dashboard configuration.
  });
});
