const { test, expect } = require('@playwright/test');
const { url, goAndAuth } = require('./helpers');

// Jellyfin is not behind Traefik forward_auth. Public API requests should reach
// Jellyfin directly, while browser SSO starts through the Jellyfin SSO plugin.
test.describe('Jellyfin', () => {
  test('public server info is not intercepted by forward auth', async ({ request }) => {
    const response = await request.get(`${url('jellyfin')}/System/Info/Public`, {
      maxRedirects: 0,
    });
    expect(response.status()).toBe(200);

    const body = await response.json();
    expect(body).toHaveProperty('StartupWizardCompleted', true);
    expect(body).toHaveProperty('ServerName');
  });

  test('admin can log in through Authentik OIDC and reach the home dashboard', async ({ page }) => {
    await goAndAuth(page, `${url('jellyfin')}/sso/OID/start/authentik`);
    await page.waitForURL('**/home.html**', { timeout: 20_000 });
    await expect(page.locator('.homeSectionsContainer, #indexPage').first())
      .toBeVisible({ timeout: 15_000 });
  });

  test('media library is accessible and a video can be played', async ({ page }) => {
    await goAndAuth(page, `${url('jellyfin')}/sso/OID/start/authentik`);
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
