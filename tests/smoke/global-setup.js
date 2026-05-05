const { chromium } = require('@playwright/test');
const path = require('path');
const fs = require('fs');
require('dotenv').config({ path: path.join(__dirname, '../.env.test') });

const DOMAIN = process.env.DOMAIN || 'zenlabs.us';
const ADMIN_USER = process.env.ADMIN_USER;
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD;
const AUTH_STATE_PATH = path.join(__dirname, '../.auth/admin.json');

module.exports = async function globalSetup() {
  if (!ADMIN_USER || !ADMIN_PASSWORD) {
    throw new Error('ADMIN_USER and ADMIN_PASSWORD must be set in tests/.env.test');
  }

  fs.mkdirSync(path.dirname(AUTH_STATE_PATH), { recursive: true });

  const browser = await chromium.launch({ args: ['--no-sandbox'] });
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await context.newPage();

  console.log(`\n[setup] Logging into Authentik at https://auth.${DOMAIN} ...`);
  // Use networkidle so the Lit/React SPA has fully rendered the login form
  await page.goto(`https://auth.${DOMAIN}/if/admin/`, { waitUntil: 'networkidle', timeout: 30_000 });

  await performAuthentikLogin(page, ADMIN_USER, ADMIN_PASSWORD);

  // After login, Authentik redirects back to /if/admin/ (the SPA shell)
  await page.waitForURL(`**/if/admin/**`, { timeout: 20_000 });
  console.log('[setup] Authentik login successful, saving session state.');

  await context.storageState({ path: AUTH_STATE_PATH });
  await browser.close();
};

/**
 * Handle the Authentik two-step login flow:
 *   1. Identification stage — enter username, click Continue
 *   2. Password stage      — enter password, click Continue
 */
async function performAuthentikLogin(page, username, password) {
  if (!page.url().includes('/if/flow/')) {
    await page.waitForURL('**/if/flow/**', { timeout: 10_000 }).catch(() => {});
  }
  if (!page.url().includes('/if/flow/')) return; // already authenticated

  // Stage 1: wait for the identification field, fill it, submit
  await page.locator('input[name="uidField"]').waitFor({ state: 'visible', timeout: 15_000 });
  await page.locator('input[name="uidField"]').fill(username);
  await page.locator('button[type="submit"]:visible').first().click();

  // Wait for stage 1 to complete: uidField is replaced by the username display text
  await page.locator('input[name="uidField"]').waitFor({ state: 'hidden', timeout: 8_000 });

  // Stage 2: fill the password field that is now the active input and submit
  await page.locator('input[name="password"]').fill(password);
  await page.locator('button[type="submit"]:visible').first().click();

  // Optional consent stage (OIDC applications)
  const authorizeBtn = page.locator('button:has-text("Allow"), button:has-text("Authorize")');
  const hasConsent = await authorizeBtn.isVisible({ timeout: 4_000 }).catch(() => false);
  if (hasConsent) await authorizeBtn.first().click();
}

module.exports.performAuthentikLogin = performAuthentikLogin;
