const { test, expect } = require('@playwright/test');
const { url, goAndAuth, handleAuthentikIfNeeded, DOMAIN } = require('./helpers');

const SECTIONS = [
  'Media',
  'Automation & Downloads',
  'Cloud & Security',
  'Network & VPN',
  'Monitoring',
  'Identity',
];

const APPS = [
  { name: 'Jellyfin',       href: `https://jellyfin.${DOMAIN}`   },
  { name: 'Navidrome',      href: `https://music.${DOMAIN}`       },
  { name: 'Audiobookshelf', href: `https://audiobooks.${DOMAIN}` },
  { name: 'Booklore',       href: `https://books.${DOMAIN}`       },
  { name: 'Jellyseerr',     href: `https://requests.${DOMAIN}`   },
  { name: 'Sonarr',         href: `https://sonarr.${DOMAIN}`     },
  { name: 'Radarr',         href: `https://radarr.${DOMAIN}`     },
  { name: 'Lidarr',         href: `https://lidarr.${DOMAIN}`     },
  { name: 'Prowlarr',       href: `https://prowlarr.${DOMAIN}`   },
  { name: 'qBittorrent',    href: `https://qbit.${DOMAIN}`       },
  { name: 'Nextcloud',      href: `https://cloud.${DOMAIN}`      },
  { name: 'Vaultwarden',    href: `https://vault.${DOMAIN}`      },
  { name: 'Headscale',      href: `https://headscale.${DOMAIN}`  },
  { name: 'WireGuard',      href: `https://vpn.${DOMAIN}`        },
  { name: 'Traefik',        href: `https://traefik.${DOMAIN}`    },
  { name: 'Uptime Kuma',    href: `https://uptime.${DOMAIN}`     },
  { name: 'Grafana',        href: `https://grafana.${DOMAIN}`    },
  { name: 'Authentik',      href: `https://auth.${DOMAIN}`       },
];

test.describe('Homarr Home board', () => {
  // Navigate to Homarr and complete OIDC login if the SSO button is shown.
  // The stored Authentik session (global-setup) means Authentik auto-authorizes
  // without showing the username/password form.
  //
  // We wait for a URL that is neither the login page (/auth/login) nor the
  // transient OIDC callback (/api/auth/callback/oidc) before asserting anything,
  // because waitForURL resolves on the 302 callback URL whose response body is
  // empty while the browser follows the final redirect to the board.
  test.beforeEach(async ({ page }) => {
    await page.goto(url('home'), { waitUntil: 'domcontentloaded', timeout: 30_000 });

    const ssoBtn = page.locator('button:has-text("Authentik")');
    if (await ssoBtn.isVisible({ timeout: 10_000 }).catch(() => false)) {
      await ssoBtn.click();
      await handleAuthentikIfNeeded(page);
      // Exclude the transient OIDC callback URL so we only resolve on the board
      await page.waitForURL(
        u => !u.href.includes('/auth/login') && !u.href.includes('/api/auth/'),
        { timeout: 30_000 }
      );
    }

    // Wait for Homarr's SPA to render board content — use the first section
    // heading as the "board is ready" signal instead of relying on networkidle,
    // which can fire before React has finished rendering the board tiles.
    await expect(page.getByText('Media', { exact: true }).first())
      .toBeVisible({ timeout: 25_000 });

    // Homarr category sections render collapsed by default (client-side state).
    // Click each header to expand so tile anchors are visible for assertions.
    for (const section of SECTIONS) {
      await page.getByText(section, { exact: true }).first().click();
    }
    // Confirm at least one tile became visible before proceeding
    await expect(
      page.locator(`a[href="https://jellyfin.zenlabs.us"], a[href="https://jellyfin.zenlabs.us/"]`).first()
    ).toBeVisible({ timeout: 10_000 });
  });

  test('lands on Home board page after OIDC login', async ({ page }) => {
    await expect(page).not.toHaveURL(/\/auth\/login/);
    await expect(page).not.toHaveURL(/\/api\/auth\//);
    // Board shell is rendered (proven by beforeEach Media wait, confirmed here)
    await expect(page.getByText('Media', { exact: true }).first()).toBeVisible();
  });

  test('all 6 category sections are visible on the board', async ({ page }) => {
    for (const section of SECTIONS) {
      await expect(
        page.getByText(section, { exact: true }).first()
      ).toBeVisible({ timeout: 10_000 });
    }
  });

  test('all 18 app tiles are present with correct href links', async ({ page }) => {
    for (const app of APPS) {
      // Each tile is an anchor element whose href is the service URL
      const link = page.locator(`a[href="${app.href}"], a[href="${app.href}/"]`).first();
      await expect(link).toBeVisible({ timeout: 10_000 });
    }
  });

  test('all 18 service URLs respond without server error', async ({ page }) => {
    const results = [];

    for (const app of APPS) {
      try {
        const resp = await page.request.get(app.href, {
          maxRedirects: 5,
          timeout: 15_000,
          failOnStatusCode: false,
        });
        results.push({ name: app.name, status: resp.status() });
      } catch (err) {
        results.push({ name: app.name, status: 0, error: err.message });
      }
    }

    console.log('\nBoard link reachability:');
    for (const r of results) {
      const ok = r.status > 0 && r.status < 500;
      console.log(`  ${ok ? '✓' : '✗'} ${r.name.padEnd(18)} HTTP ${r.status}${r.error ? '  (' + r.error + ')' : ''}`);
    }

    const failed = results.filter(r => r.status === 0 || r.status >= 500);
    expect(
      failed,
      `Services returning 5xx or connection error: ${failed.map(f => `${f.name}(${f.status})`).join(', ')}`
    ).toHaveLength(0);
  });
});
