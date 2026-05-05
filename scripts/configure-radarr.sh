#!/usr/bin/env bash
# Configures Radarr: adds qBittorrent as download client and /movies as root folder.
# Called automatically by install.sh; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
set -a; source .env; set +a

RADARR_BASE="http://localhost:7878"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

radarr_get() {
  docker compose exec -T radarr \
    curl -sf "${RADARR_BASE}/$1" -H "X-Api-Key: ${RADARR_API}" 2>/dev/null
}

echo "Waiting for Radarr to be ready..."
RADARR_API=""
retries=0
until [[ -n "${RADARR_API}" ]] && \
      docker compose exec -T radarr \
        curl -sf -o /dev/null "${RADARR_BASE}/api/v3/system/status" \
          -H "X-Api-Key: ${RADARR_API}" 2>/dev/null; do
  RADARR_API=$(docker compose exec -T radarr \
    sed -n 's|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p' /config/config.xml 2>/dev/null | head -1 || true)
  retries=$((retries + 1))
  [[ $retries -gt 36 ]] && { echo "ERROR: Radarr did not become ready in 3 minutes."; exit 1; }
  sleep 5
done

echo "Checking Radarr download client..."
existing=$(radarr_get "api/v3/downloadclient" | grep -c '"QBittorrent"' || true)

if [[ "${existing}" -gt 0 ]]; then
  echo "qBittorrent download client already configured in Radarr."
else
  echo "Adding qBittorrent download client to Radarr..."
  u="$(json_escape "${ADMIN_USER}")"
  p="$(json_escape "${ADMIN_PASSWORD}")"

  result=$(docker compose exec -T \
    -e RADARR_API="${RADARR_API}" \
    -e QBIT_USER="${u}" \
    -e QBIT_PASS="${p}" \
    radarr sh -c \
    'curl -sf -X POST "http://localhost:7878/api/v3/downloadclient" \
       -H "X-Api-Key: ${RADARR_API}" \
       -H "Content-Type: application/json" \
       -d "{\"name\":\"qBittorrent\",\"implementation\":\"QBittorrent\",\"configContract\":\"QBittorrentSettings\",\"enable\":true,\"protocol\":\"torrent\",\"priority\":1,\"removeCompletedDownloads\":true,\"removeFailedDownloads\":true,\"fields\":[{\"name\":\"host\",\"value\":\"qbittorrent\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"useSsl\",\"value\":false},{\"name\":\"urlBase\",\"value\":\"\"},{\"name\":\"username\",\"value\":\"${QBIT_USER}\"},{\"name\":\"password\",\"value\":\"${QBIT_PASS}\"},{\"name\":\"movieCategory\",\"value\":\"radarr\"},{\"name\":\"recentMoviePriority\",\"value\":0},{\"name\":\"olderMoviePriority\",\"value\":0},{\"name\":\"initialState\",\"value\":0}]}"' \
    2>/dev/null)

  echo "${result}" | grep -q '"id"' || { echo "ERROR: Failed to add qBittorrent to Radarr. Response: ${result}"; exit 1; }

  final=$(radarr_get "api/v3/downloadclient" | grep -c '"QBittorrent"' || true)
  [[ "${final}" -gt 0 ]] || { echo "ERROR: qBittorrent not found in Radarr after adding."; exit 1; }
  echo "qBittorrent download client added to Radarr."
fi

echo "Checking Radarr root folder..."
has_movies=$(radarr_get "api/v3/rootfolder" | grep -c '"/movies"' || true)

if [[ "${has_movies}" -gt 0 ]]; then
  echo "Root folder /movies already configured in Radarr."
else
  echo "Adding root folder /movies to Radarr..."
  result=$(docker compose exec -T \
    -e RADARR_API="${RADARR_API}" \
    radarr sh -c \
    'curl -sf -X POST "http://localhost:7878/api/v3/rootfolder" \
       -H "X-Api-Key: ${RADARR_API}" \
       -H "Content-Type: application/json" \
       -d "{\"path\":\"/movies\"}"' 2>/dev/null)
  echo "${result}" | grep -q '"id"' || { echo "ERROR: Failed to add /movies root folder to Radarr."; exit 1; }
  echo "Root folder /movies added to Radarr."
fi

echo "Done! Radarr is configured with qBittorrent and /movies root folder."
