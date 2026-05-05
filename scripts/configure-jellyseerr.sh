#!/usr/bin/env bash
# Completes Jellyseerr first-run setup against the local Jellyfin service,
# then connects Sonarr and Radarr so requests flow through the full pipeline.
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

# Read Sonarr / Radarr API keys from their running containers.
# These are available because configure-sonarr.sh / configure-radarr.sh ran first.
get_arr_key() {
  local svc="$1" cfg="$2"
  docker compose exec -T "${svc}" \
    sed -n 's|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p' "${cfg}" 2>/dev/null | head -1 || true
}

SONARR_API=$(get_arr_key sonarr /config/config.xml)
RADARR_API=$(get_arr_key radarr /config/config.xml)

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
  -e SONARR_API="${SONARR_API}" \
  -e RADARR_API="${RADARR_API}" \
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

async function arrFetch(baseUrl, apiKey, path) {
  const r = await fetch(`${baseUrl}${path}`, { headers: { 'X-Api-Key': apiKey } });
  if (!r.ok) throw new Error(`${baseUrl}${path} → ${r.status}`);
  return r.json();
}

async function main() {
  const { body: publicSettings } = await request('/api/v1/settings/public');
  const alreadyInitialized = Boolean(publicSettings.initialized);
  if (alreadyInitialized) {
    console.log('Jellyseerr already initialized; verifying Jellyfin connection.');
  }

  console.log('Signing in to Jellyseerr with Jellyfin admin...');
  let login;
  try {
    // When already initialized, sending hostname/port causes "already configured" error.
    // Only pass the full setup payload on first run.
    const authBody = alreadyInitialized
      ? {
          username: process.env.JF_USER,
          password: process.env.JF_PASS,
        }
      : {
          username: process.env.JF_USER,
          password: process.env.JF_PASS,
          email: process.env.ADMIN_EMAIL,
          hostname: process.env.JF_HOST,
          port: Number(process.env.JF_PORT || 8096),
          useSsl: false,
          urlBase: '',
          serverType: 2,
        };
    login = await request('/api/v1/auth/jellyfin', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(authBody),
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

  if (!alreadyInitialized) {
    await request('/api/v1/settings/initialize', {
      method: 'POST',
      headers: { Cookie: cookie },
    });
  }

  const { body: finalSettings } = await request('/api/v1/settings/public');
  if (!finalSettings.initialized) {
    throw new Error('Jellyseerr did not report initialized=true after setup.');
  }

  // ── Radarr connection ───────────────────────────────────────────────────────
  const radarrApiKey = process.env.RADARR_API || '';
  if (radarrApiKey) {
    const { body: existingRadarr } = await request('/api/v1/settings/radarr', { headers: { Cookie: cookie } });
    if (Array.isArray(existingRadarr) && existingRadarr.length > 0) {
      console.log('Radarr already connected to Jellyseerr.');
    } else {
      console.log('Connecting Radarr to Jellyseerr...');
      const [profiles, rootFolders] = await Promise.all([
        arrFetch('http://radarr:7878', radarrApiKey, '/api/v3/qualityprofile'),
        arrFetch('http://radarr:7878', radarrApiKey, '/api/v3/rootfolder'),
      ]);
      if (!profiles.length) throw new Error('Radarr returned no quality profiles — run configure-radarr.sh first.');
      const profile = profiles[0];
      const dir = rootFolders.length ? rootFolders[0].path : '/movies';

      await request('/api/v1/settings/radarr', {
        method: 'POST',
        headers: { Cookie: cookie, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: 'Radarr',
          hostname: 'radarr',
          port: 7878,
          apiKey: radarrApiKey,
          useSsl: false,
          baseUrl: '',
          activeProfileId: profile.id,
          activeProfileName: profile.name,
          activeDirectory: dir,
          is4k: false,
          minimumAvailability: 'released',
          isDefault: true,
          syncEnabled: true,
          preventSearch: false,
          tagRequests: false,
        }),
      });

      const { body: finalRadarr } = await request('/api/v1/settings/radarr', { headers: { Cookie: cookie } });
      if (!Array.isArray(finalRadarr) || finalRadarr.length === 0) {
        throw new Error('Radarr not found in Jellyseerr settings after adding.');
      }
      console.log(`Radarr connected (profile: ${profile.name}, dir: ${dir}).`);
    }
  } else {
    console.log('WARNING: RADARR_API not available — skipping Radarr connection.');
  }

  // ── Sonarr connection ───────────────────────────────────────────────────────
  const sonarrApiKey = process.env.SONARR_API || '';
  if (sonarrApiKey) {
    const { body: existingSonarr } = await request('/api/v1/settings/sonarr', { headers: { Cookie: cookie } });
    if (Array.isArray(existingSonarr) && existingSonarr.length > 0) {
      console.log('Sonarr already connected to Jellyseerr.');
    } else {
      console.log('Connecting Sonarr to Jellyseerr...');
      const [profiles, rootFolders] = await Promise.all([
        arrFetch('http://sonarr:8989', sonarrApiKey, '/api/v3/qualityprofile'),
        arrFetch('http://sonarr:8989', sonarrApiKey, '/api/v3/rootfolder'),
      ]);
      if (!profiles.length) throw new Error('Sonarr returned no quality profiles — run configure-sonarr.sh first.');
      const profile = profiles[0];
      const dir = rootFolders.length ? rootFolders[0].path : '/tv';

      await request('/api/v1/settings/sonarr', {
        method: 'POST',
        headers: { Cookie: cookie, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name: 'Sonarr',
          hostname: 'sonarr',
          port: 8989,
          apiKey: sonarrApiKey,
          useSsl: false,
          baseUrl: '',
          activeProfileId: profile.id,
          activeProfileName: profile.name,
          activeAnimeProfileId: profile.id,
          activeAnimeProfileName: profile.name,
          activeDirectory: dir,
          activeAnimeDirectory: dir,
          is4k: false,
          enableSeasonFolders: true,
          isDefault: true,
          syncEnabled: true,
          preventSearch: false,
          tagRequests: false,
        }),
      });

      const { body: finalSonarr } = await request('/api/v1/settings/sonarr', { headers: { Cookie: cookie } });
      if (!Array.isArray(finalSonarr) || finalSonarr.length === 0) {
        throw new Error('Sonarr not found in Jellyseerr settings after adding.');
      }
      console.log(`Sonarr connected (profile: ${profile.name}, dir: ${dir}).`);
    }
  } else {
    console.log('WARNING: SONARR_API not available — skipping Sonarr connection.');
  }

  console.log('Done! Jellyseerr is initialized and connected to Jellyfin, Radarr, and Sonarr.');
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
NODE
