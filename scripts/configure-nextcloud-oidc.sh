#!/usr/bin/env bash
# Run this AFTER Nextcloud has fully initialized (first boot takes a few minutes).
# Installs and configures the user_oidc app to authenticate via Authentik.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
# shellcheck source=/dev/null
set -a; source .env; set +a

occ() {
  docker compose exec -T nextcloud php occ "$@"
}

echo "Waiting for Nextcloud to be ready (first boot can take several minutes)..."
retries=0
until occ status --output json 2>/dev/null | grep -q '"installed":true'; do
  retries=$((retries+1))
  [[ $retries -gt 72 ]] && { echo "ERROR: Nextcloud did not become ready in 6 minutes."; exit 1; }
  sleep 5
done
echo "Nextcloud is ready."

echo "Ensuring user_oidc app is installed and enabled..."
if occ app:enable user_oidc >/dev/null 2>&1; then
  echo "user_oidc app is enabled."
else
  occ app:install user_oidc >/dev/null
  echo "user_oidc app installed and enabled."
fi

if occ user_oidc:provider authentik >/dev/null 2>&1; then
  echo "Updating existing OIDC provider 'authentik'..."
else
  echo "Creating OIDC provider 'authentik'..."
fi

# user_oidc providers are keyed by identifier. Re-running this command updates
# the existing provider instead of creating duplicates.
occ user_oidc:provider authentik \
  --clientid="${NEXTCLOUD_OIDC_CLIENT_ID}" \
  --clientsecret="${NEXTCLOUD_OIDC_CLIENT_SECRET}" \
  --discoveryuri="https://auth.${DOMAIN}/application/o/nextcloud/.well-known/openid-configuration" \
  --unique-uid=0 \
  --mapping-uid=preferred_username

if ! occ user_oidc:provider authentik >/dev/null 2>&1; then
  echo "ERROR: Nextcloud OIDC provider verification failed."
  exit 1
fi

echo "Disabling Nextcloud's password login (OIDC only)..."
# Comment out the next line to keep password login as fallback
# occ config:app:set --value=0 user_oidc allow_multiple_user_backends

echo "Done! Nextcloud OIDC is configured."
echo "Users can now log in at https://cloud.${DOMAIN} via Authentik."
