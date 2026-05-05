const { test, expect } = require('@playwright/test');
const { url, goAndAuth } = require('./helpers');

// Booklore has not had its initial admin account created (see ISSUE-014).
// Both tests detect the /setup page and skip until resolved.
test.describe('Booklore', () => {
  async function skipIfSetup(page) {
    const atSetup = await page.locator('text=Setup your initial admin account').isVisible({ timeout: 3_000 }).catch(() => false);
    if (atSetup) {
      test.skip(true, 'ISSUE-014: Booklore initial admin account not created — service at /setup page');
      return true;
    }
    return false;
  }

  test('book library loads after forward auth', async ({ page }) => {
    await goAndAuth(page, url('books'));
    if (await skipIfSetup(page)) return;

    await expect(page.locator('app-root').first()).toBeVisible({ timeout: 20_000 });
  });

  test('library/books section is accessible', async ({ page }) => {
    await goAndAuth(page, url('books'));
    if (await skipIfSetup(page)) return;

    await page.waitForTimeout(3000);

    const booksNav = page.locator('a[href*="books"], a[href*="library"]').first();
    const hasNav = await booksNav.isVisible({ timeout: 6_000 }).catch(() => false);
    if (hasNav) await booksNav.click();

    await expect(page.locator('app-root').first()).toBeVisible({ timeout: 20_000 });
  });
});
