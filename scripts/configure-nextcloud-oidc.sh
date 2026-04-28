#!/usr/bin/env bash
# Run this AFTER Nextcloud has fully initialized (first boot takes a few minutes).
# Installs and configures the user_oidc app to authenticate via Authentik.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
source .env

echo "Waiting for Nextcloud to be ready (first boot can take several minutes)..."
retries=0
until docker compose exec -T nextcloud php occ status --output json 2>/dev/null | grep -q '"installed":true'; do
  retries=$((retries+1))
  [[ $retries -gt 72 ]] && { echo "ERROR: Nextcloud did not become ready in 6 minutes."; exit 1; }
  sleep 5
done
echo "Nextcloud is ready."

echo "Installing user_oidc app..."
docker compose exec -T nextcloud php occ app:install user_oidc 2>/dev/null || \
  docker compose exec -T nextcloud php occ app:enable user_oidc

echo "Configuring OIDC provider..."
docker compose exec -T nextcloud php occ user_oidc:provider authentik \
  --clientid="${NEXTCLOUD_OIDC_CLIENT_ID}" \
  --clientsecret="${NEXTCLOUD_OIDC_CLIENT_SECRET}" \
  --discoveryuri="https://auth.${DOMAIN}/application/o/nextcloud/.well-known/openid-configuration" \
  --unique-uid=0 \
  --mapping-uid=preferred_username

echo "Disabling Nextcloud's password login (OIDC only)..."
# Comment out the next line to keep password login as fallback
# docker compose exec -T nextcloud php occ config:app:set --value=0 user_oidc allow_multiple_user_backends

echo "Done! Nextcloud OIDC is configured."
echo "Users can now log in at https://cloud.${DOMAIN} via Authentik."
