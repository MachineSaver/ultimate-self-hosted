#!/usr/bin/env bash
# Creates the Headscale admin user and generates a reusable pre-auth key.
# Called automatically by install.sh; safe to re-run to generate new keys.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
# shellcheck source=/dev/null
set -a; source .env; set +a

echo "Creating Headscale user '${ADMIN_USER}'..."
docker compose exec -T headscale headscale users create "${ADMIN_USER}" 2>/dev/null \
  || echo "User '${ADMIN_USER}' already exists — skipping creation."

echo "Generating pre-auth key (reusable, 24h)..."
USER_ID=$(docker compose exec -T headscale headscale users list -o json 2>/dev/null \
  | python3 -c "import sys,json; users=json.load(sys.stdin); print(next(str(u['id']) for u in users if u['name']=='${ADMIN_USER}'))" 2>/dev/null || true)

if [[ -z "${USER_ID}" ]]; then
  echo "ERROR: Could not find user '${ADMIN_USER}' in Headscale."
  exit 1
fi

KEY=$(docker compose exec -T headscale \
  headscale preauthkeys create \
    --user "${USER_ID}" \
    --reusable \
    --expiration 24h \
    -o json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || true)

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
