#!/usr/bin/env bash
# Installs and configures Jellyfin's SSO Authentication plugin for Authentik OIDC.
# Called automatically by install.sh after scripts/configure-jellyfin.sh; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
# shellcheck source=/dev/null
set -a; source .env; set +a

JELLYFIN_ADMIN_USER="${JELLYFIN_ADMIN_USER:-${ADMIN_USER}}"
JELLYFIN_ADMIN_PASSWORD="${JELLYFIN_ADMIN_PASSWORD:-${ADMIN_PASSWORD}}"
JELLYFIN_OIDC_PROVIDER_NAME="${JELLYFIN_OIDC_PROVIDER_NAME:-authentik}"
JELLYFIN_OIDC_DISPLAY_NAME="${JELLYFIN_OIDC_DISPLAY_NAME:-Sign in with Authentik}"
JELLYFIN_OIDC_PLUGIN_REPOSITORY_NAME="${JELLYFIN_OIDC_PLUGIN_REPOSITORY_NAME:-Jellyfin SSO}"
JELLYFIN_OIDC_PLUGIN_REPOSITORY_URL="${JELLYFIN_OIDC_PLUGIN_REPOSITORY_URL:-https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json}"

wait_for_jellyfin() {
  echo "Waiting for Jellyfin to be ready..."
  local retries=0
  until docker compose exec -T jellyfin curl -fsS http://localhost:8096/System/Info/Public >/dev/null 2>&1; do
    retries=$((retries+1))
    [[ $retries -gt 36 ]] && { echo "ERROR: Jellyfin did not become ready in 3 minutes."; exit 1; }
    sleep 5
  done
}

restart_jellyfin() {
  echo "Restarting Jellyfin to load the SSO plugin..."
  docker compose restart jellyfin >/dev/null
  wait_for_jellyfin
}

wait_for_jellyfin

configure_output=$(
docker compose exec -T \
  -e JF_BASE_URL="http://jellyfin:8096" \
  -e JF_ADMIN_USER="${JELLYFIN_ADMIN_USER}" \
  -e JF_ADMIN_PASSWORD="${JELLYFIN_ADMIN_PASSWORD}" \
  -e JF_DOMAIN="${DOMAIN}" \
  -e JF_OIDC_CLIENT_ID="${JELLYFIN_OIDC_CLIENT_ID}" \
  -e JF_OIDC_CLIENT_SECRET="${JELLYFIN_OIDC_CLIENT_SECRET}" \
  -e JF_OIDC_PROVIDER_NAME="${JELLYFIN_OIDC_PROVIDER_NAME}" \
  -e JF_OIDC_DISPLAY_NAME="${JELLYFIN_OIDC_DISPLAY_NAME}" \
  -e JF_PLUGIN_REPOSITORY_NAME="${JELLYFIN_OIDC_PLUGIN_REPOSITORY_NAME}" \
  -e JF_PLUGIN_REPOSITORY_URL="${JELLYFIN_OIDC_PLUGIN_REPOSITORY_URL}" \
  jellyseerr node <<'NODE'
const baseUrl = process.env.JF_BASE_URL;
const authHeader = 'MediaBrowser Client="ultimate-self-hosted", Device="installer", DeviceId="ultimate-self-hosted-installer", Version="1.0"';

async function request(path, options = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    ...options,
    headers: {
      Accept: 'application/json',
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...(options.headers || {}),
    },
  });

  const text = await response.text();
  let body = null;
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
  }

  if (!response.ok) {
    const detail = typeof body === 'string' ? body : JSON.stringify(body);
    throw new Error(`${options.method || 'GET'} ${path} failed with HTTP ${response.status}: ${detail}`);
  }

  return body;
}

function tokenHeader(token) {
  return { Authorization: `MediaBrowser Token="${token}"` };
}

async function authenticate() {
  const auth = await request('/Users/AuthenticateByName', {
    method: 'POST',
    headers: { Authorization: authHeader },
    body: JSON.stringify({
      Username: process.env.JF_ADMIN_USER,
      Pw: process.env.JF_ADMIN_PASSWORD,
    }),
  });

  if (!auth?.AccessToken) {
    throw new Error('Jellyfin authentication did not return an access token.');
  }
  return auth.AccessToken;
}

async function ensureApiKey(token) {
  const appName = 'ultimate-self-hosted-jellyfin-oidc';
  let keys = await request('/Auth/Keys', { headers: tokenHeader(token) });
  let key = (keys?.Items || keys || []).find(item => item.AppName === appName || item.Name === appName);
  if (key?.AccessToken) return key.AccessToken;

  await request(`/Auth/Keys?app=${encodeURIComponent(appName)}`, {
    method: 'POST',
    headers: tokenHeader(token),
  });

  keys = await request('/Auth/Keys', { headers: tokenHeader(token) });
  key = (keys?.Items || keys || []).find(item => item.AppName === appName || item.Name === appName);
  if (!key?.AccessToken) {
    throw new Error(`Could not create or read Jellyfin API key '${appName}'.`);
  }
  return key.AccessToken;
}

async function ensurePluginRepository(token) {
  const name = process.env.JF_PLUGIN_REPOSITORY_NAME;
  const url = process.env.JF_PLUGIN_REPOSITORY_URL;
  const repositories = await request('/Repositories', { headers: tokenHeader(token) }).catch(() => []);
  const exists = Array.isArray(repositories) && repositories.some(repo => repo.Name === name || repo.Url === url);
  if (exists) {
    console.log(`Plugin repository '${name}' already exists.`);
    return;
  }

  console.log(`Adding Jellyfin plugin repository '${name}'...`);
  await request('/Repositories', {
    method: 'POST',
    headers: tokenHeader(token),
    body: JSON.stringify([{ Name: name, Url: url, Enabled: true }]),
  });
}

async function ssoPluginResponds(apiKey) {
  const response = await fetch(`${baseUrl}/sso/OID/Get?api_key=${encodeURIComponent(apiKey)}`);
  return response.ok;
}

function parseVersion(version) {
  return String(version || '0').split(/[.-]/).map(part => Number.parseInt(part, 10) || 0);
}

function compareVersions(a, b) {
  const left = parseVersion(a);
  const right = parseVersion(b);
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i += 1) {
    if ((left[i] || 0) !== (right[i] || 0)) return (left[i] || 0) - (right[i] || 0);
  }
  return 0;
}

async function installPluginIfNeeded(token, apiKey) {
  if (await ssoPluginResponds(apiKey)) {
    console.log('Jellyfin SSO plugin is already loaded.');
    return false;
  }

  const packages = await request('/Packages', { headers: tokenHeader(token) });
  const candidates = (Array.isArray(packages) ? packages : [])
    .filter(pkg => /sso|single.?sign|authentication/i.test(`${pkg.Name || pkg.name || ''} ${pkg.Description || pkg.description || ''} ${pkg.Overview || pkg.overview || ''}`));

  if (candidates.length === 0) {
    throw new Error('Jellyfin SSO plugin was not found in the plugin catalog after adding the repository.');
  }

  const plugin = candidates.find(pkg => /sso/i.test(pkg.Name || pkg.name || '')) || candidates[0];
  const versions = [...(plugin.Versions || plugin.versions || [])].sort((a, b) => compareVersions(b.Version || b.version, a.Version || a.version));
  const selected = versions.find(version => {
    const targetAbi = version.targetAbi || version.TargetAbi || '';
    return !targetAbi || /10\./.test(targetAbi);
  }) || versions[0];
  const selectedVersion = selected?.Version || selected?.version;
  const pluginName = plugin.Name || plugin.name;
  if (!selectedVersion) {
    throw new Error(`Jellyfin SSO plugin '${pluginName}' has no installable versions in the catalog.`);
  }

  const assemblyGuid = selected.Guid || selected.guid || plugin.Guid || plugin.guid || plugin.Id || plugin.id || '';
  const params = new URLSearchParams({ version: selectedVersion });
  if (assemblyGuid) params.set('AssemblyGuid', assemblyGuid);
  if (selected.RepositoryUrl || selected.repositoryUrl || plugin.RepositoryUrl || plugin.repositoryUrl || process.env.JF_PLUGIN_REPOSITORY_URL) {
    params.set('repositoryUrl', selected.RepositoryUrl || selected.repositoryUrl || plugin.RepositoryUrl || plugin.repositoryUrl || process.env.JF_PLUGIN_REPOSITORY_URL);
  }

  console.log(`Installing Jellyfin plugin '${pluginName}' ${selectedVersion}...`);
  await request(`/Packages/Installed/${encodeURIComponent(pluginName)}?${params.toString()}`, {
    method: 'POST',
    headers: tokenHeader(token),
  });
  return true;
}

async function configureOidc(apiKey) {
  const provider = process.env.JF_OIDC_PROVIDER_NAME;
  const domain = process.env.JF_DOMAIN;
  const payload = {
    oidEndpoint: `https://auth.${domain}/application/o/jellyfin/`,
    oidClientId: process.env.JF_OIDC_CLIENT_ID,
    oidSecret: process.env.JF_OIDC_CLIENT_SECRET,
    enabled: true,
    enableAuthorization: true,
    enableAllFolders: true,
    enabledFolders: [],
    roles: [],
    adminRoles: [],
    enableFolderRoles: false,
    folderRoleMapping: [],
    enableLiveTvRoles: false,
    liveTvRoles: [],
    liveTvManagementRoles: [],
    enableLiveTv: true,
    enableLiveTvManagement: false,
    roleClaim: 'groups',
    oidScopes: ['openid', 'email', 'profile'],
    defaultUsernameClaim: 'preferred_username',
    schemeOverride: 'https',
  };

  console.log(`Configuring Jellyfin OIDC provider '${provider}'...`);
  const response = await fetch(`${baseUrl}/sso/OID/Add/${encodeURIComponent(provider)}?api_key=${encodeURIComponent(apiKey)}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    throw new Error(`POST /sso/OID/Add/${provider} failed with HTTP ${response.status}: ${await response.text()}`);
  }
}

async function main() {
  const token = await authenticate();
  await ensurePluginRepository(token);
  const apiKey = await ensureApiKey(token);
  const installed = await installPluginIfNeeded(token, apiKey);
  if (installed) {
    console.log('PLUGIN_INSTALL_REQUIRES_RESTART');
    return;
  }
  await configureOidc(apiKey);
  console.log(`Done! Jellyfin OIDC is configured. Start URL: https://jellyfin.${process.env.JF_DOMAIN}/sso/OID/start/${process.env.JF_OIDC_PROVIDER_NAME}`);
}

main().catch(error => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
NODE
)

printf '%s\n' "${configure_output}"

if grep -q 'PLUGIN_INSTALL_REQUIRES_RESTART' <<<"${configure_output}"; then
  restart_jellyfin
  exec "$0"
fi
