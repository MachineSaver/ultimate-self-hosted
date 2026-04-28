#!/usr/bin/env bash
# Sets qBittorrent WebUI credentials to match the install admin credentials.
# Called automatically by install.sh; only works once (temp password is single-use).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
# shellcheck source=/dev/null
set -a; source .env; set +a

echo "Waiting for qBittorrent WebUI..."
retries=0
until docker compose exec -T qbittorrent curl -sf http://localhost:8080 >/dev/null 2>&1; do
  retries=$((retries+1))
  [[ $retries -gt 24 ]] && { echo "ERROR: qBittorrent WebUI did not become ready in 2 minutes."; exit 1; }
  sleep 5
done

QBIT_TEMP=$(docker compose logs qbittorrent 2>/dev/null \
  | grep -i "temporary password" | tail -1 \
  | rev | cut -d' ' -f1 | rev | tr -d '[:space:]' || true)

if [[ -z "${QBIT_TEMP}" ]]; then
  echo "No temporary password found — credentials may already have been set. Skipping."
  exit 0
fi

echo "Setting qBittorrent credentials..."
result=$(docker compose exec -T qbittorrent bash -c "
  sid=\$(curl -sf \
    --header 'Referer: http://localhost:8080' \
    --data 'username=admin&password=${QBIT_TEMP}' \
    http://localhost:8080/api/v2/auth/login)
  if [[ \"\${sid}\" != 'Ok.' ]]; then
    echo 'LOGIN_FAILED'
    exit 0
  fi
  # Re-login using cookie jar so subsequent call is authenticated
  curl -sf \
    --header 'Referer: http://localhost:8080' \
    --data 'username=admin&password=${QBIT_TEMP}' \
    --cookie-jar /tmp/qbt.txt \
    http://localhost:8080/api/v2/auth/login >/dev/null
  curl -sf \
    --header 'Referer: http://localhost:8080' \
    --cookie /tmp/qbt.txt \
    --data 'json={\"web_ui_username\":\"${ADMIN_USER}\",\"web_ui_password\":\"${ADMIN_PASSWORD}\"}' \
    http://localhost:8080/api/v2/app/setPreferences
  echo 'OK'
")

if [[ "${result}" == "LOGIN_FAILED" ]]; then
  echo "Login with temporary password failed — credentials may already have been set. Skipping."
  exit 0
fi

echo "Done! qBittorrent credentials set (username: ${ADMIN_USER})."
