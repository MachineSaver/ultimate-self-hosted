#!/usr/bin/env bash
# Sets qBittorrent WebUI credentials to match the install admin credentials.
# Called automatically by install.sh; safe to re-run if credentials are already set.
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

echo "Checking whether qBittorrent already accepts the desired credentials..."
if docker compose exec -T \
  -e QBIT_ADMIN_USER="${ADMIN_USER}" \
  -e QBIT_ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
  qbittorrent bash -s <<'BASH' >/dev/null 2>&1
set -euo pipefail
result=$(curl -sf \
  --header 'Referer: http://localhost:8080' \
  --data-urlencode "username=${QBIT_ADMIN_USER}" \
  --data-urlencode "password=${QBIT_ADMIN_PASSWORD}" \
  http://localhost:8080/api/v2/auth/login)
[[ "${result}" == 'Ok.' ]]
BASH
then
  echo "qBittorrent credentials already match desired admin credentials."
  exit 0
fi

QBIT_TEMP=$(docker compose logs qbittorrent 2>/dev/null \
  | grep -i "temporary password" | tail -1 \
  | rev | cut -d' ' -f1 | rev | tr -d '[:space:]' || true)

if [[ -z "${QBIT_TEMP}" ]]; then
  echo "ERROR: qBittorrent does not accept desired credentials, and no temporary password was found in logs."
  echo "Re-run after a fresh qBittorrent initialization or set the WebUI credentials manually."
  exit 1
fi

echo "Setting qBittorrent credentials..."
result=$(docker compose exec -T \
  -e QBIT_TEMP="${QBIT_TEMP}" \
  -e QBIT_ADMIN_USER="${ADMIN_USER}" \
  -e QBIT_ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
  qbittorrent bash -s <<'BASH'
set -euo pipefail

json_escape() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  val="${val//$'\n'/\\n}"
  val="${val//$'\r'/\\r}"
  val="${val//$'\t'/\\t}"
  printf '%s' "$val"
}

sid=$(curl -sf \
  --header 'Referer: http://localhost:8080' \
  --data-urlencode "username=admin" \
  --data-urlencode "password=${QBIT_TEMP}" \
  http://localhost:8080/api/v2/auth/login)

if [[ "${sid}" != 'Ok.' ]]; then
  echo 'LOGIN_FAILED'
  exit 0
fi

curl -sf \
  --header 'Referer: http://localhost:8080' \
  --data-urlencode "username=admin" \
  --data-urlencode "password=${QBIT_TEMP}" \
  --cookie-jar /tmp/qbt.txt \
  http://localhost:8080/api/v2/auth/login >/dev/null

prefs=$(printf '{"web_ui_username":"%s","web_ui_password":"%s"}' \
  "$(json_escape "${QBIT_ADMIN_USER}")" \
  "$(json_escape "${QBIT_ADMIN_PASSWORD}")")

curl -sf \
  --header 'Referer: http://localhost:8080' \
  --cookie /tmp/qbt.txt \
  --data-urlencode "json=${prefs}" \
  http://localhost:8080/api/v2/app/setPreferences

echo 'OK'
BASH
)

if [[ "${result}" == "LOGIN_FAILED" ]]; then
  echo "ERROR: Login with qBittorrent temporary password failed, and desired credentials are not active."
  exit 1
fi

if docker compose exec -T \
  -e QBIT_ADMIN_USER="${ADMIN_USER}" \
  -e QBIT_ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
  qbittorrent bash -s <<'BASH' >/dev/null 2>&1
set -euo pipefail
result=$(curl -sf \
  --header 'Referer: http://localhost:8080' \
  --data-urlencode "username=${QBIT_ADMIN_USER}" \
  --data-urlencode "password=${QBIT_ADMIN_PASSWORD}" \
  http://localhost:8080/api/v2/auth/login)
[[ "${result}" == 'Ok.' ]]
BASH
then
  echo "Done! qBittorrent credentials set (username: ${ADMIN_USER})."
else
  echo "ERROR: qBittorrent credential verification failed after update."
  exit 1
fi
