#!/usr/bin/env bash
# Configures Lidarr: adds qBittorrent as download client and /music as root folder.
# Called automatically by install.sh; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
set -a; source .env; set +a

LIDARR_BASE="http://localhost:8686"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

lidarr_get() {
  docker compose exec -T lidarr \
    curl -sf "${LIDARR_BASE}/$1" -H "X-Api-Key: ${LIDARR_API}" 2>/dev/null
}

echo "Waiting for Lidarr to be ready..."
LIDARR_API=""
retries=0
until [[ -n "${LIDARR_API}" ]] && \
      docker compose exec -T lidarr \
        curl -sf -o /dev/null "${LIDARR_BASE}/api/v1/system/status" \
          -H "X-Api-Key: ${LIDARR_API}" 2>/dev/null; do
  LIDARR_API=$(docker compose exec -T lidarr \
    sed -n 's|.*<ApiKey>\([^<]*\)</ApiKey>.*|\1|p' /config/config.xml 2>/dev/null | head -1 || true)
  retries=$((retries + 1))
  [[ $retries -gt 36 ]] && { echo "ERROR: Lidarr did not become ready in 3 minutes."; exit 1; }
  sleep 5
done

echo "Checking Lidarr download client..."
existing=$(lidarr_get "api/v1/downloadclient" | grep -c '"QBittorrent"' || true)

if [[ "${existing}" -gt 0 ]]; then
  echo "qBittorrent download client already configured in Lidarr."
else
  echo "Adding qBittorrent download client to Lidarr..."
  u="$(json_escape "${ADMIN_USER}")"
  p="$(json_escape "${ADMIN_PASSWORD}")"

  result=$(docker compose exec -T \
    -e LIDARR_API="${LIDARR_API}" \
    -e QBIT_USER="${u}" \
    -e QBIT_PASS="${p}" \
    lidarr sh -c \
    'curl -sf -X POST "http://localhost:8686/api/v1/downloadclient" \
       -H "X-Api-Key: ${LIDARR_API}" \
       -H "Content-Type: application/json" \
       -d "{\"name\":\"qBittorrent\",\"implementation\":\"QBittorrent\",\"configContract\":\"QBittorrentSettings\",\"enable\":true,\"protocol\":\"torrent\",\"priority\":1,\"removeCompletedDownloads\":true,\"removeFailedDownloads\":true,\"fields\":[{\"name\":\"host\",\"value\":\"qbittorrent\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"useSsl\",\"value\":false},{\"name\":\"urlBase\",\"value\":\"\"},{\"name\":\"username\",\"value\":\"${QBIT_USER}\"},{\"name\":\"password\",\"value\":\"${QBIT_PASS}\"},{\"name\":\"musicCategory\",\"value\":\"lidarr\"},{\"name\":\"recentPriority\",\"value\":0},{\"name\":\"olderPriority\",\"value\":0},{\"name\":\"initialState\",\"value\":0}]}"' \
    2>/dev/null)

  echo "${result}" | grep -q '"id"' || { echo "ERROR: Failed to add qBittorrent to Lidarr. Response: ${result}"; exit 1; }

  final=$(lidarr_get "api/v1/downloadclient" | grep -c '"QBittorrent"' || true)
  [[ "${final}" -gt 0 ]] || { echo "ERROR: qBittorrent not found in Lidarr after adding."; exit 1; }
  echo "qBittorrent download client added to Lidarr."
fi

echo "Checking Lidarr root folder..."
has_music=$(lidarr_get "api/v1/rootfolder" | grep -c '"/music"' || true)

if [[ "${has_music}" -gt 0 ]]; then
  echo "Root folder /music already configured in Lidarr."
else
  echo "Adding root folder /music to Lidarr..."
  # Lidarr requires DefaultQualityProfileId and DefaultMetadataProfileId.
  # Profile ID 1 is "Any" quality and "Standard" metadata — always seeded by Lidarr on first run.
  result=$(docker compose exec -T \
    -e LIDARR_API="${LIDARR_API}" \
    lidarr sh -c \
    'curl -sf -X POST "http://localhost:8686/api/v1/rootfolder" \
       -H "X-Api-Key: ${LIDARR_API}" \
       -H "Content-Type: application/json" \
       -d "{\"name\":\"Music\",\"path\":\"/music\",\"defaultQualityProfileId\":1,\"defaultMetadataProfileId\":1}"' 2>/dev/null)
  echo "${result}" | grep -q '"path"' || { echo "ERROR: Failed to add /music root folder to Lidarr. Response: ${result}"; exit 1; }
  echo "Root folder /music added to Lidarr."
fi

echo "Done! Lidarr is configured with qBittorrent and /music root folder."
