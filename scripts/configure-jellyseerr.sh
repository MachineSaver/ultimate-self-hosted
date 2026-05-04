#!/usr/bin/env bash
# Completes Jellyseerr first-run setup against the local Jellyfin service.
# Called automatically by install.sh; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
# shellcheck source=/dev/null
set -a; source .env; set +a

JELLYSEERR_URL="${JELLYSEERR_URL:-http://localhost:5055}"
JELLYFIN_INTERNAL_HOST="${JELLYFIN_INTERNAL_HOST:-jellyfin}"
JELLYFIN_INTERNAL_PORT="${JELLYFIN_INTERNAL_PORT:-8096}"
JELLYFIN_ADMIN_USER="${JELLYFIN_ADMIN_USER:-${ADMIN_USER}}"
JELLYFIN_ADMIN_PASSWORD="${JELLYFIN_ADMIN_PASSWORD:-${ADMIN_PASSWORD}}"

echo "Waiting for Jellyseerr to be ready..."
retries=0
until docker compose exec -T jellyseerr node -e \
  "fetch('${JELLYSEERR_URL}/api/v1/status').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
  2>/dev/null; do
  retries=$((retries+1))
  [[ $retries -gt 36 ]] && { echo "ERROR: Jellyseerr did not become ready in 3 minutes."; exit 1; }
  sleep 5
done

docker compose exec -T \
  -e JS_URL="${JELLYSEERR_URL}" \
  -e JF_USER="${JELLYFIN_ADMIN_USER}" \
  -e JF_PASS="${JELLYFIN_ADMIN_PASSWORD}" \
  -e ADMIN_EMAIL="${ADMIN_EMAIL}" \
  -e JF_HOST="${JELLYFIN_INTERNAL_HOST}" \
  -e JF_PORT="${JELLYFIN_INTERNAL_PORT}" \
  jellyseerr node - <<'NODE'
const baseUrl = process.env.JS_URL;

async function request(path, options = {}) {
  const response = await fetch(`${baseUrl}${path}`, options);
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : undefined;
  } catch {
    body = text;
  }
  if (!response.ok) {
    const detail = typeof body === 'object' ? body.message || body.error || JSON.stringify(body) : body;
    const error = new Error(`${options.method || 'GET'} ${path} failed (${response.status}): ${detail}`);
    error.status = response.status;
    throw error;
  }
  return { response, body };
}

function getCookie(response) {
  const setCookie = typeof response.headers.getSetCookie === 'function'
    ? response.headers.getSetCookie()
    : [response.headers.get('set-cookie')].filter(Boolean);
  return setCookie.map((cookie) => cookie.split(';')[0]).join('; ');
}

async function main() {
  const { body: publicSettings } = await request('/api/v1/settings/public');
  if (publicSettings.initialized) {
    console.log('Jellyseerr already initialized.');
    return;
  }

  console.log('Signing in to Jellyseerr with Jellyfin admin...');
  let login;
  try {
    login = await request('/api/v1/auth/jellyfin', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        username: process.env.JF_USER,
        password: process.env.JF_PASS,
        email: process.env.ADMIN_EMAIL,
        hostname: process.env.JF_HOST,
        port: Number(process.env.JF_PORT || 8096),
        useSsl: false,
        urlBase: '',
        serverType: 2,
      }),
    });
  } catch (error) {
    throw new Error(
      `${error.message}\nJellyseerr setup requires JELLYFIN_ADMIN_USER/JELLYFIN_ADMIN_PASSWORD in .env to match the initialized Jellyfin admin.`
    );
  }

  const cookie = getCookie(login.response);
  if (!cookie) {
    throw new Error('Jellyseerr login succeeded but did not return a session cookie.');
  }

  console.log('Syncing Jellyfin libraries into Jellyseerr...');
  const synced = await request('/api/v1/settings/jellyfin/library?sync=true', {
    headers: { Cookie: cookie },
  });
  const libraries = Array.isArray(synced.body) ? synced.body : [];
  const libraryIds = libraries.map((library) => library.id).filter(Boolean);

  if (libraryIds.length > 0) {
    await request(`/api/v1/settings/jellyfin/library?enable=${encodeURIComponent(libraryIds.join(','))}`, {
      headers: { Cookie: cookie },
    });
    console.log(`Enabled ${libraryIds.length} Jellyfin librar${libraryIds.length === 1 ? 'y' : 'ies'} in Jellyseerr.`);
  } else {
    console.log('No Jellyfin libraries were returned; continuing with setup initialized.');
  }

  await request('/api/v1/settings/initialize', {
    method: 'POST',
    headers: { Cookie: cookie },
  });

  const { body: finalSettings } = await request('/api/v1/settings/public');
  if (!finalSettings.initialized) {
    throw new Error('Jellyseerr did not report initialized=true after setup.');
  }

  console.log('Done! Jellyseerr is initialized and connected to Jellyfin.');
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
NODE
