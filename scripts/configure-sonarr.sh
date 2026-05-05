#!/usr/bin/env bash
# Configures Sonarr: adds qBittorrent as download client and /tv as root folder.
# Called automatically by install.sh; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
set -a; source .env; set +a

SONARR_BASE="http://localhost:8989"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

sonarr_get() {
  docker compose exec -T sonarr \
    curl -sf "${SONARR_BASE}/$1" -H "X-Api-Key: ${SONARR_API}" 2>/dev/null
}

echo "Waiting for Sonarr to be ready..."
SONARR_API=""
retries=0
until [[ -n "${SONARR_API}" ]] && \
      docker compose exec -T sonarr \
        curl -sf -o /dev/null "${SONARR_BASE}/api/v3/system/status" \
          -H "X-Api-Key: ${SONARR_API}" 2>/dev/null; do
  SONARR_API=$(docker compose exec -T sonarr \
    sed -n 's|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p' /config/config.xml 2>/dev/null | head -1 || true)
  retries=$((retries + 1))
  [[ $retries -gt 36 ]] && { echo "ERROR: Sonarr did not become ready in 3 minutes."; exit 1; }
  sleep 5
done

echo "Checking Sonarr download client..."
existing=$(sonarr_get "api/v3/downloadclient" | grep -c '"QBittorrent"' || true)

if [[ "${existing}" -gt 0 ]]; then
  echo "qBittorrent download client already configured in Sonarr."
else
  echo "Adding qBittorrent download client to Sonarr..."
  u="$(json_escape "${ADMIN_USER}")"
  p="$(json_escape "${ADMIN_PASSWORD}")"

  result=$(docker compose exec -T \
    -e SONARR_API="${SONARR_API}" \
    -e QBIT_USER="${u}" \
    -e QBIT_PASS="${p}" \
    sonarr sh -c \
    'curl -sf -X POST "http://localhost:8989/api/v3/downloadclient" \
       -H "X-Api-Key: ${SONARR_API}" \
       -H "Content-Type: application/json" \
       -d "{\"name\":\"qBittorrent\",\"implementation\":\"QBittorrent\",\"configContract\":\"QBittorrentSettings\",\"enable\":true,\"protocol\":\"torrent\",\"priority\":1,\"removeCompletedDownloads\":true,\"removeFailedDownloads\":true,\"fields\":[{\"name\":\"host\",\"value\":\"qbittorrent\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"useSsl\",\"value\":false},{\"name\":\"urlBase\",\"value\":\"\"},{\"name\":\"username\",\"value\":\"${QBIT_USER}\"},{\"name\":\"password\",\"value\":\"${QBIT_PASS}\"},{\"name\":\"tvCategory\",\"value\":\"tv-sonarr\"},{\"name\":\"recentTvPriority\",\"value\":0},{\"name\":\"olderTvPriority\",\"value\":0},{\"name\":\"initialState\",\"value\":0}]}"' \
    2>/dev/null)

  echo "${result}" | grep -q '"id"' || { echo "ERROR: Failed to add qBittorrent to Sonarr. Response: ${result}"; exit 1; }

  final=$(sonarr_get "api/v3/downloadclient" | grep -c '"QBittorrent"' || true)
  [[ "${final}" -gt 0 ]] || { echo "ERROR: qBittorrent not found in Sonarr after adding."; exit 1; }
  echo "qBittorrent download client added to Sonarr."
fi

echo "Checking Sonarr root folder..."
has_tv=$(sonarr_get "api/v3/rootfolder" | grep -c '"/tv"' || true)

if [[ "${has_tv}" -gt 0 ]]; then
  echo "Root folder /tv already configured in Sonarr."
else
  echo "Adding root folder /tv to Sonarr..."
  result=$(docker compose exec -T \
    -e SONARR_API="${SONARR_API}" \
    sonarr sh -c \
    'curl -sf -X POST "http://localhost:8989/api/v3/rootfolder" \
       -H "X-Api-Key: ${SONARR_API}" \
       -H "Content-Type: application/json" \
       -d "{\"path\":\"/tv\"}"' 2>/dev/null)
  echo "${result}" | grep -q '"id"' || { echo "ERROR: Failed to add /tv root folder to Sonarr."; exit 1; }
  echo "Root folder /tv added to Sonarr."
fi

echo "Done! Sonarr is configured with qBittorrent and /tv root folder."
