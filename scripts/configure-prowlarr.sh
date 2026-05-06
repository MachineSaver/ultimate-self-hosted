#!/usr/bin/env bash
# Configures Prowlarr: registers Sonarr/Radarr/Lidarr as sync targets and adds
# a baseline set of public indexers (YTS for movies, EZTV for TV).
# Called automatically by install.sh; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
set -a; source .env; set +a

get_api_key() {
  local svc="$1" cfg_path="$2"
  local key retries=0
  until key=$(docker compose exec -T "${svc}" \
    sed -n 's|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p' "${cfg_path}" 2>/dev/null | head -1) \
      && [[ -n "${key}" ]]; do
    retries=$((retries + 1))
    [[ $retries -gt 24 ]] && { echo "ERROR: Could not read API key for ${svc}."; exit 1; }
    sleep 5
  done
  printf '%s' "${key}"
}

wait_ready() {
  local svc="$1" url="$2" api_key="$3"
  local retries=0
  echo "Waiting for ${svc} to be ready..."
  until docker compose exec -T "${svc}" \
      curl -sf -o /dev/null "${url}" -H "X-Api-Key: ${api_key}" 2>/dev/null; do
    retries=$((retries + 1))
    [[ $retries -gt 36 ]] && { echo "ERROR: ${svc} did not become ready in 3 minutes."; exit 1; }
    sleep 5
  done
}

PROWLARR_API=$(get_api_key prowlarr /config/config.xml)
SONARR_API=$(get_api_key sonarr /config/config.xml)
RADARR_API=$(get_api_key radarr /config/config.xml)
LIDARR_API=$(get_api_key lidarr /config/config.xml)

wait_ready prowlarr "http://localhost:9696/api/v1/system/status" "${PROWLARR_API}"

docker compose exec -T \
  -e PROWLARR_API="${PROWLARR_API}" \
  -e SONARR_API="${SONARR_API}" \
  -e RADARR_API="${RADARR_API}" \
  -e LIDARR_API="${LIDARR_API}" \
  jellyseerr node - <<'NODE'
const P_BASE = 'http://prowlarr:9696';
const API    = process.env.PROWLARR_API;

async function req(method, path, body) {
  const opts = {
    method,
    headers: { 'X-Api-Key': API, 'Content-Type': 'application/json' },
  };
  if (body !== undefined) opts.body = JSON.stringify(body);
  const r = await fetch(`${P_BASE}${path}`, opts);
  const text = await r.text();
  if (!r.ok) throw new Error(`${method} ${path} → ${r.status}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
}

async function ensureApp(existing, cfg) {
  const found = existing.find(a => a.implementation === cfg.implementation);
  if (found) {
    const merged = {
      ...found,
      name: cfg.name,
      enable: true,
      syncLevel: cfg.syncLevel,
      fields: found.fields.map(field => {
        const desired = cfg.fields.find(candidate => candidate.name === field.name);
        return desired ? { ...field, value: desired.value } : field;
      }),
    };
    await req('PUT', `/api/v1/applications/${found.id}`, merged);
    console.log(`  ${cfg.name} already registered in Prowlarr — updated sync settings.`);
    return;
  }
  await req('POST', '/api/v1/applications', cfg);
  console.log(`  Added ${cfg.name} to Prowlarr.`);
}

async function ensureIndexer(existing, schemas, appProfileId, defName) {
  if (existing.find(i => i.definitionName === defName)) {
    console.log(`  Indexer ${defName} already configured.`);
    return true;
  }
  const schema = schemas.find(s => s.definitionName === defName);
  if (!schema) {
    console.log(`  WARNING: indexer schema '${defName}' not found in Prowlarr — skipping.`);
    return false;
  }
  try {
    await req('POST', '/api/v1/indexer', {
      ...schema,
      enable: true,
      appProfileId,
      name: schema.name || defName,
    });
    console.log(`  Added indexer: ${defName}`);
    return true;
  } catch (err) {
    console.log(`  WARNING: Could not add indexer '${defName}': ${err.message.split('\n')[0]}`);
    return false;
  }
}

async function main() {
  const [apps, indexers, schemas, appProfiles] = await Promise.all([
    req('GET', '/api/v1/applications'),
    req('GET', '/api/v1/indexer'),
    req('GET', '/api/v1/indexer/schema'),
    req('GET', '/api/v1/appprofile'),
  ]);
  const appProfileId = appProfiles.length ? appProfiles[0].id : 1;

  console.log('Registering arr apps in Prowlarr...');

  await ensureApp(apps, {
    name: 'Sonarr',
    implementation: 'Sonarr',
    configContract: 'SonarrSettings',
    enable: true,
    syncLevel: 'addOnly',
    fields: [
      { name: 'prowlarrUrl',   value: 'http://prowlarr:9696' },
      { name: 'baseUrl',       value: 'http://sonarr:8989' },
      { name: 'apiKey',        value: process.env.SONARR_API },
      { name: 'syncCategories', value: [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080] },
      { name: 'animeSyncCategories', value: [] },
    ],
  });

  await ensureApp(apps, {
    name: 'Radarr',
    implementation: 'Radarr',
    configContract: 'RadarrSettings',
    enable: true,
    syncLevel: 'addOnly',
    fields: [
      { name: 'prowlarrUrl', value: 'http://prowlarr:9696' },
      { name: 'baseUrl',     value: 'http://radarr:7878' },
      { name: 'apiKey',      value: process.env.RADARR_API },
      { name: 'syncCategories', value: [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080] },
    ],
  });

  await ensureApp(apps, {
    name: 'Lidarr',
    implementation: 'Lidarr',
    configContract: 'LidarrSettings',
    enable: true,
    syncLevel: 'addOnly',
    fields: [
      { name: 'prowlarrUrl', value: 'http://prowlarr:9696' },
      { name: 'baseUrl',     value: 'http://lidarr:8686' },
      { name: 'apiKey',      value: process.env.LIDARR_API },
      { name: 'syncCategories', value: [3000, 3010, 3020, 3030, 3040, 3050] },
    ],
  });

  console.log('Adding public indexers to Prowlarr...');
  // YTS: high-quality movie rips (movies → categories 2000–2080)
  await ensureIndexer(indexers, schemas, appProfileId, 'yts');
  // Try several TV/general trackers in order until one succeeds
  const tvTrackers = ['eztv', 'thepiratebay', '1337x', 'torrentgalaxy'];
  for (const tracker of tvTrackers) {
    const ok = await ensureIndexer(indexers, schemas, appProfileId, tracker);
    if (ok) break;
  }

  // Verify
  const finalApps = await req('GET', '/api/v1/applications');
  const names = finalApps.map(a => a.name);
  for (const expected of ['Sonarr', 'Radarr', 'Lidarr']) {
    const app = finalApps.find(a => a.name === expected);
    if (!app) throw new Error(`${expected} not found in Prowlarr after setup.`);
    if (!app.enable || app.syncLevel === 'disabled') {
      throw new Error(`${expected} Prowlarr sync is not enabled after setup.`);
    }
  }
  console.log('Done! Prowlarr connected to Sonarr, Radarr, Lidarr with baseline indexers.');
}

main().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
NODE
