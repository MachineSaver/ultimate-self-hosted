#!/usr/bin/env bash
# Creates the Headscale admin user and generates a reusable pre-auth key.
# Called automatically by install.sh; safe to re-run to generate new keys.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
# shellcheck source=/dev/null
set -a; source .env; set +a

echo "Waiting for Headscale to be ready..."
retries=0
until docker compose exec -T headscale headscale version >/dev/null 2>&1; do
  retries=$((retries+1))
  [[ $retries -gt 24 ]] && { echo "ERROR: Headscale did not become ready in 2 minutes."; exit 1; }
  sleep 5
done

echo "Creating Headscale user '${ADMIN_USER}'..."
docker compose exec -T headscale headscale users create "${ADMIN_USER}" 2>/dev/null \
  || echo "User '${ADMIN_USER}' already exists — skipping creation."

USER_ID=$(docker compose exec -T headscale headscale users list -o json 2>/dev/null \
  | awk -v name="${ADMIN_USER}" '
      /"id":/ {
        id = $0
        gsub(/[^0-9]/, "", id)
      }
      /"name":/ {
        user = $0
        sub(/^[[:space:]]*"name":[[:space:]]*"/, "", user)
        sub(/",?[[:space:]]*$/, "", user)
        if (user == name) {
          print id
          exit
        }
      }
    ' || true)

if [[ -z "${USER_ID}" ]]; then
  echo "ERROR: Headscale user '${ADMIN_USER}' was not found after configuration."
  exit 1
fi

echo "Generating pre-auth key (reusable, 24h)..."
KEY=$(docker compose exec -T headscale \
  headscale preauthkeys create \
    --user "${USER_ID}" \
    --reusable \
    --expiration 24h \
    -o json 2>/dev/null \
  | tr -d '[:space:]' | grep -o '"key":"[^"]*"' | cut -d'"' -f4 || true)

if [[ -z "${KEY}" ]]; then
  echo "ERROR: Could not generate pre-auth key."
  exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Headscale pre-auth key (expires in 24h, reusable):"
echo ""
echo "  ${KEY}"
echo ""
echo "  Connect a device:"
echo "  tailscale login --login-server https://headscale.${DOMAIN} \\"
echo "                  --authkey ${KEY}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
