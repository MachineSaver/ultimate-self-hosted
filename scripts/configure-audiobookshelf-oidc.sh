#!/usr/bin/env bash
# Configures Audiobookshelf OpenID Connect via the ABS REST API.
# Called automatically by install.sh; safe to re-run at any time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
# shellcheck source=/dev/null
set -a; source .env; set +a

echo "Waiting for Audiobookshelf to be ready..."
retries=0
until docker compose exec -T audiobookshelf node -e \
  "fetch('http://localhost:13378/status').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
  2>/dev/null; do
  retries=$((retries+1))
  [[ $retries -gt 24 ]] && { echo "ERROR: Audiobookshelf did not become ready in 2 minutes."; exit 1; }
  sleep 5
done

docker compose exec -T \
  -e ABS_USER="${ADMIN_USER}" \
  -e ABS_PASS="${ADMIN_PASSWORD}" \
  -e ABS_DOMAIN="${DOMAIN}" \
  -e ABS_CLIENT_ID="${AUDIOBOOKSHELF_OIDC_CLIENT_ID}" \
  -e ABS_CLIENT_SECRET="${AUDIOBOOKSHELF_OIDC_CLIENT_SECRET}" \
  audiobookshelf node - << 'JSEOF'
const BASE = 'http://localhost:13378';
const { ABS_USER, ABS_PASS, ABS_DOMAIN, ABS_CLIENT_ID, ABS_CLIENT_SECRET } = process.env;

async function main() {
  const status = await fetch(`${BASE}/status`).then(r => r.json());

  if (status.isInit === false || status.needsInit === true) {
    process.stdout.write('Initializing Audiobookshelf root user...\n');
    const res = await fetch(`${BASE}/init`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ newRoot: { username: ABS_USER, password: ABS_PASS } })
    });
    if (!res.ok) throw new Error(`Init failed (${res.status}): ${await res.text()}`);
    process.stdout.write('Root user created.\n');
  }

  const login = await fetch(`${BASE}/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: ABS_USER, password: ABS_PASS })
  }).then(r => r.json());

  const token = login?.user?.token;
  if (!token) throw new Error('Login failed — check ADMIN_USER and ADMIN_PASSWORD in .env');

  const patch = await fetch(`${BASE}/api/auth-settings`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${token}` },
    body: JSON.stringify({
      authActiveAuthMethods: ['local', 'openid'],
      authOpenIDIssuer: `https://auth.${ABS_DOMAIN}/application/o/audiobookshelf/`,
      authOpenIDClientID: ABS_CLIENT_ID,
      authOpenIDClientSecret: ABS_CLIENT_SECRET,
      authOpenIDAutoLaunch: false,
      authOpenIDAutoRegister: true
    })
  });
  if (!patch.ok) throw new Error(`Auth settings update failed (${patch.status}): ${await patch.text()}`);
  process.stdout.write('Done! Audiobookshelf OIDC configured.\n');
}

main().catch(e => { process.stderr.write(`ERROR: ${e.message}\n`); process.exit(1); });
JSEOF
