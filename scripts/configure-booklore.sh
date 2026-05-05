#!/usr/bin/env bash
# Creates the Booklore initial admin account via the setup API.
# Called automatically by install.sh; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
# shellcheck source=/dev/null
set -a; source .env; set +a

BL_URL="http://localhost:6060"

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

echo "Waiting for Booklore to be ready..."
retries=0
until docker compose exec -T booklore wget -q -O /dev/null "${BL_URL}/api/v1/healthcheck" 2>/dev/null; do
  retries=$((retries+1))
  [[ $retries -gt 36 ]] && { echo "ERROR: Booklore did not become ready in 3 minutes."; exit 1; }
  sleep 5
done

echo "Checking Booklore setup status..."
status=$(docker compose exec -T booklore wget -q -O - "${BL_URL}/api/v1/setup/status" 2>/dev/null || true)

if printf '%s' "${status}" | grep -q '"data":true'; then
  echo "Booklore admin account already exists; skipping setup."
  exit 0
fi

echo "Creating Booklore admin account for '${ADMIN_USER}'..."

body=$(printf '{"username":"%s","email":"%s","name":"%s","password":"%s"}' \
  "$(json_str "${ADMIN_USER}")" \
  "$(json_str "${ADMIN_EMAIL}")" \
  "$(json_str "${ADMIN_USER}")" \
  "$(json_str "${ADMIN_PASSWORD}")")

response=$(docker compose exec -T booklore \
  sh -c 'curl -sf -X POST http://localhost:6060/api/v1/setup \
    -H "Content-Type: application/json" --data-binary @-' <<< "${body}")

if ! printf '%s' "${response}" | grep -q '"statusCode":200'; then
  echo "ERROR: Booklore setup API returned unexpected response: ${response}"
  exit 1
fi

verify=$(docker compose exec -T booklore wget -q -O - "${BL_URL}/api/v1/setup/status" 2>/dev/null || true)
if ! printf '%s' "${verify}" | grep -q '"data":true'; then
  echo "ERROR: Booklore setup/status did not confirm completion after account creation."
  exit 1
fi

echo "Done! Booklore admin account '${ADMIN_USER}' created successfully."
