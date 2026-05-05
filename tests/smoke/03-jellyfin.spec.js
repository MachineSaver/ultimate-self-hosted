const { test, expect } = require('@playwright/test');
const { url, goAndAuth, ADMIN_USER, ADMIN_PASSWORD } = require('./helpers');

// Jellyfin is behind Traefik forward_auth — we rely on the stored Authentik session
// to pass through, then log in to Jellyfin's own form with the local admin account.
test.describe('Jellyfin', () => {
  test('admin can log in and reach the home dashboard', async ({ page }) => {
    await goAndAuth(page, url('jellyfin'));

    // Jellyfin presents its own login form after forward_auth passes
    await page.locator('#txtManualName').waitFor({ state: 'visible', timeout: 15_000 });
    await page.locator('#txtManualName').fill(ADMIN_USER);
    await page.locator('#txtManualPassword').fill(ADMIN_PASSWORD);
    await page.locator('button:has-text("Sign In")').click();

    // Home dashboard should appear
    await page.waitForURL('**/home.html**', { timeout: 20_000 });
    await expect(page.locator('.homeSectionsContainer, #indexPage').first())
      .toBeVisible({ timeout: 15_000 });
  });

  test('media library is accessible and a video can be played', async ({ page }) => {
    await goAndAuth(page, url('jellyfin'));

    await page.locator('#txtManualName').waitFor({ state: 'visible', timeout: 15_000 });
    await page.locator('#txtManualName').fill(ADMIN_USER);
    await page.locator('#txtManualPassword').fill(ADMIN_PASSWORD);
    await page.locator('button:has-text("Sign In")').click();
    await page.waitForURL('**/home.html**', { timeout: 20_000 });

    // Look for a media card on the home page
    const mediaCard = page.locator('.card, .cardBox').first();
    const hasMedia = await mediaCard.isVisible({ timeout: 8_000 }).catch(() => false);

    if (!hasMedia) {
      test.skip(true, 'No media found on home page — add movies or TV shows to test playback');
      return;
    }

    await mediaCard.click();

    // Play button on the detail page
    const playBtn = page.locator(
      'button[data-action="play"], .detailButton-button, .playButton, button:has-text("Play")'
    ).first();
    await expect(playBtn).toBeVisible({ timeout: 10_000 });
    await playBtn.click();

    // Wait for the video player, then verify it's playing
    await expect(page.locator('#videoPlayer, video').first()).toBeVisible({ timeout: 15_000 });
    await page.waitForTimeout(5000);
    const isPlaying = await page.evaluate(() => {
      const v = document.querySelector('video');
      return v ? (!v.paused && v.currentTime > 0) : false;
    });
    expect(isPlaying, 'Video should be playing (currentTime > 0, not paused)').toBe(true);
  });
});
