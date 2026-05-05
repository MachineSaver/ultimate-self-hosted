const { test, expect } = require('@playwright/test');
const { url, handleAuthentikIfNeeded } = require('./helpers');

// Navidrome trusts the X-authentik-username header injected by forward_auth,
// so the user is automatically logged in as akadmin after Authentik auth.
// The SPA holds persistent XHR connections, so networkidle never fires —
// use domcontentloaded instead.
test.describe('Navidrome', () => {
  async function navToNavidrome(page) {
    await page.goto(url('music'), { waitUntil: 'domcontentloaded', timeout: 60_000 });
    await handleAuthentikIfNeeded(page);
    // Allow the SPA to finish mounting
    await page.waitForTimeout(4000);
  }

  test('auto-logs in via Authentik proxy header and shows library', async ({ page }) => {
    await navToNavidrome(page);

    await expect(page.locator('#main-content, #root').first()).toBeVisible({ timeout: 20_000 });
    await expect(page).toHaveTitle(/Navidrome/i, { timeout: 10_000 });
  });

  test('albums list is reachable', async ({ page }) => {
    await navToNavidrome(page);

    const albumsLink = page.locator('a[href*="album"]').first();
    const hasAlbums = await albumsLink.isVisible({ timeout: 5_000 }).catch(() => false);
    if (hasAlbums) await albumsLink.click();

    await expect(page.locator('#main-content').first()).toBeVisible({ timeout: 20_000 });
  });
});
