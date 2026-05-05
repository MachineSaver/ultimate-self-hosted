const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../.env.test') });

const DOMAIN = process.env.DOMAIN || 'zenlabs.us';
const ADMIN_USER = process.env.ADMIN_USER || 'akadmin';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || '';

function url(subdomain) {
  return `https://${subdomain}.${DOMAIN}`;
}

/**
 * Authentik two-step login:
 *   1. Enter username → click Continue → wait for uidField to disappear
 *   2. Enter password → click Continue
 * Also handles the optional OIDC consent stage.
 */
async function handleAuthentikIfNeeded(page) {
  if (!page.url().includes('/if/flow/')) {
    await page.waitForURL('**/if/flow/**', { timeout: 8_000 }).catch(() => {});
  }
  if (!page.url().includes('/if/flow/')) return;

  // Stage 1: username
  const uidField = page.locator('input[name="uidField"]');
  await uidField.waitFor({ state: 'visible', timeout: 15_000 });
  await uidField.fill(ADMIN_USER);
  await page.locator('button[type="submit"]:visible').first().click();

  // Wait for stage transition (uidField disappears)
  await uidField.waitFor({ state: 'hidden', timeout: 8_000 });

  // Stage 2: password
  await page.locator('input[name="password"]').fill(ADMIN_PASSWORD);
  await page.locator('button[type="submit"]:visible').first().click();

  // Optional OIDC consent stage
  const authorizeBtn = page.locator('button:has-text("Allow"), button:has-text("Authorize")');
  const hasConsent = await authorizeBtn.isVisible({ timeout: 4_000 }).catch(() => false);
  if (hasConsent) await authorizeBtn.first().click();
}

/** Navigate to a URL and handle any Authentik login redirect. */
async function goAndAuth(page, targetUrl) {
  await page.goto(targetUrl, { waitUntil: 'networkidle', timeout: 30_000 });
  await handleAuthentikIfNeeded(page);
}

module.exports = { url, handleAuthentikIfNeeded, goAndAuth, DOMAIN, ADMIN_USER, ADMIN_PASSWORD };
