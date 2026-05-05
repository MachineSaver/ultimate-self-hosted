const { test, expect } = require('@playwright/test');
const { url, goAndAuth, ADMIN_USER, ADMIN_PASSWORD } = require('./helpers');

// Jellyseerr sits behind Traefik forward_auth but also has its own login.
// After forward_auth passes, log in with the Jellyfin admin account.
async function loginJellyseerr(page) {
  await goAndAuth(page, url('requests') + '/login');
  await page.getByText('Login with Jellyfin').click();
  await page.locator('#username').waitFor({ state: 'visible', timeout: 5_000 });
  await page.locator('#username').fill(ADMIN_USER);
  await page.locator('#password').fill(ADMIN_PASSWORD);
  await page.getByRole('button', { name: 'Sign In' }).click();
  await page.waitForURL('https://requests.' + (process.env.DOMAIN || 'zenlabs.us') + '/', { timeout: 20_000 });
}

test.describe('Jellyseerr', () => {
  test('homepage loads and shows media discovery', async ({ page }) => {
    await loginJellyseerr(page);
    await expect(page.getByText('Trending').first()).toBeVisible({ timeout: 15_000 });
  });

  test('search returns results for a known title', async ({ page }) => {
    await loginJellyseerr(page);
    await page.goto(url('requests') + '/search?query=The%20Matrix', { waitUntil: 'networkidle', timeout: 30_000 });
    await page.waitForTimeout(2000);

    // Results render as links with /movie/ or /tv/ in their href
    const resultLink = page.locator('a[href*="/movie/"], a[href*="/tv/"]').first();
    await expect(resultLink).toBeVisible({ timeout: 15_000 });

    // Click the first result and verify the detail page loads
    await resultLink.click();
    await page.waitForTimeout(3000);
    const requestState = page.locator('button:has-text("Request"), button:has-text("Requested"), span:has-text("Request")').first();
    await expect(requestState).toBeVisible({ timeout: 15_000 });
  });

  test('requests page structure loads', async ({ page }) => {
    await loginJellyseerr(page);
    await page.goto(url('requests') + '/requests', { waitUntil: 'networkidle', timeout: 30_000 });
    await page.waitForTimeout(2000);

    // Filter tabs are always rendered regardless of whether there are requests
    await expect(page.getByText('Requests').first()).toBeVisible({ timeout: 15_000 });
    // "Show All Requests" button is always present as a page-level control
    await expect(page.getByText('Show All Requests').or(page.getByText('No results.')).first())
      .toBeVisible({ timeout: 15_000 });
  });
});
