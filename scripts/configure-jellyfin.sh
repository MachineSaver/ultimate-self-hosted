#!/usr/bin/env bash
# Completes Jellyfin's first-run setup and creates baseline media libraries.
# Called automatically by install.sh; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
# shellcheck source=/dev/null
set -a; source .env; set +a

JELLYFIN_SERVER_NAME="${JELLYFIN_SERVER_NAME:-Jellyfin}"
JELLYFIN_ADMIN_USER="${JELLYFIN_ADMIN_USER:-${ADMIN_USER}}"
JELLYFIN_ADMIN_PASSWORD="${JELLYFIN_ADMIN_PASSWORD:-${ADMIN_PASSWORD}}"
JELLYFIN_MOVIES_DIR="${JELLYFIN_MOVIES_DIR:-/media/movies}"
JELLYFIN_TV_DIR="${JELLYFIN_TV_DIR:-/media/tv}"
JELLYFIN_MUSIC_DIR="${JELLYFIN_MUSIC_DIR:-/media/music}"
JELLYFIN_BOOKS_DIR="${JELLYFIN_BOOKS_DIR:-/media/books}"
JELLYFIN_AUDIOBOOKS_DIR="${JELLYFIN_AUDIOBOOKS_DIR:-/media/audiobooks}"

BASE_URL="http://localhost:8096"
AUTH_HEADER='MediaBrowser Client="ultimate-self-hosted", Device="installer", DeviceId="ultimate-self-hosted-installer", Version="1.0"'
STARTUP_ALREADY_COMPLETED=false
JELLYFIN_TOKEN=""

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

jellyfin_curl() {
  local method="$1" path="$2"
  docker compose exec -T jellyfin curl -fsS -X "${method}" "${BASE_URL}${path}"
}

jellyfin_json() {
  local method="$1" path="$2" json="$3"
  docker compose exec -T -e JF_JSON="${json}" jellyfin sh -lc \
    "curl -fsS -X '${method}' -H 'Content-Type: application/json' --data \"\$JF_JSON\" '${BASE_URL}${path}'"
}

wait_for_first_user() {
  local retries=0
  until jellyfin_curl GET /Startup/User | grep -q '"Name"'; do
    retries=$((retries+1))
    [[ $retries -gt 24 ]] && { echo "ERROR: Jellyfin did not create its initial user in 2 minutes."; exit 1; }
    sleep 5
  done
}

wait_for_jellyfin() {
  echo "Waiting for Jellyfin to be ready..."
  local retries=0
  until jellyfin_curl GET /System/Info/Public >/dev/null 2>&1; do
    retries=$((retries+1))
    [[ $retries -gt 36 ]] && { echo "ERROR: Jellyfin did not become ready in 3 minutes."; exit 1; }
    sleep 5
  done
}

startup_completed() {
  jellyfin_curl GET /System/Info/Public | grep -q '"StartupWizardCompleted":true'
}

complete_startup_wizard() {
  if startup_completed; then
    echo "Jellyfin startup wizard already completed."
    STARTUP_ALREADY_COMPLETED=true
    return 0
  fi

  echo "Completing Jellyfin startup wizard..."
  local server_name admin_user admin_pass
  server_name="$(json_escape "${JELLYFIN_SERVER_NAME}")"
  admin_user="$(json_escape "${JELLYFIN_ADMIN_USER}")"
  admin_pass="$(json_escape "${JELLYFIN_ADMIN_PASSWORD}")"

  jellyfin_json POST /Startup/Configuration \
    "{\"UICulture\":\"en-US\",\"MetadataCountryCode\":\"US\",\"PreferredMetadataLanguage\":\"en\",\"ServerName\":\"${server_name}\"}" >/dev/null

  # Jellyfin seeds a temporary first user asynchronously after startup.
  # Posting /Startup/User before that row exists returns a 500.
  wait_for_first_user

  jellyfin_json POST /Startup/User \
    "{\"Name\":\"${admin_user}\",\"Password\":\"${admin_pass}\"}" >/dev/null

  jellyfin_json POST /Startup/RemoteAccess \
    '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null

  jellyfin_json POST /Startup/Complete '{}' >/dev/null

  echo "Jellyfin startup wizard completed."
}

authenticate() {
  local admin_user admin_pass auth_json token
  admin_user="$(json_escape "${JELLYFIN_ADMIN_USER}")"
  admin_pass="$(json_escape "${JELLYFIN_ADMIN_PASSWORD}")"
  auth_json="{\"Username\":\"${admin_user}\",\"Pw\":\"${admin_pass}\"}"

  token=$(
    docker compose exec -T \
      -e JF_JSON="${auth_json}" \
      -e JF_AUTH="${AUTH_HEADER}" \
      jellyfin sh -lc \
      "curl -fsS -H 'Content-Type: application/json' -H \"Authorization: \$JF_AUTH\" --data \"\$JF_JSON\" '${BASE_URL}/Users/AuthenticateByName' 2>/dev/null" \
      | sed -n 's/.*"AccessToken":"\([^"]*\)".*/\1/p'
  ) || true

  [[ -n "${token}" ]] || {
    if [[ "${STARTUP_ALREADY_COMPLETED}" == "true" ]]; then
      echo "WARNING: Jellyfin is already initialized, but API login failed for JELLYFIN_ADMIN_USER from .env."
      echo "Skipping library automation. Re-run after aligning Jellyfin credentials with .env."
      exit 0
    fi
    echo "ERROR: Jellyfin API login failed for JELLYFIN_ADMIN_USER from .env."
    echo "If Jellyfin was set up manually with different credentials, update .env or create libraries manually."
    exit 1
  }

  JELLYFIN_TOKEN="${token}"
}

library_exists() {
  local token="$1" name="$2"
  docker compose exec -T -e JF_TOKEN="${token}" -e JF_AUTH="${AUTH_HEADER}" jellyfin sh -lc \
    "curl -fsS -H \"Authorization: MediaBrowser Token=\\\"\$JF_TOKEN\\\"\" '${BASE_URL}/Library/VirtualFolders'" \
    | grep -F "\"Name\":\"${name}\"" >/dev/null
}

path_exists() {
  local path="$1"
  docker compose exec -T -e JF_PATH="${path}" jellyfin sh -lc 'test -d "$JF_PATH"'
}

create_library() {
  local token="$1" name="$2" collection_type="$3" path="$4"

  if library_exists "${token}" "${name}"; then
    echo "Library '${name}' already exists — skipping."
    return 0
  fi

  if ! path_exists "${path}"; then
    echo "Library path '${path}' is missing in Jellyfin — skipping '${name}'."
    return 0
  fi

  echo "Creating Jellyfin library '${name}' (${path})..."
  docker compose exec -T \
    -e JF_TOKEN="${token}" \
    -e JF_AUTH="${AUTH_HEADER}" \
    -e JF_NAME="${name}" \
    -e JF_TYPE="${collection_type}" \
    -e JF_PATH="${path}" \
    jellyfin sh -lc \
    "curl -fsS -G -X POST -H \"Authorization: MediaBrowser Token=\\\"\$JF_TOKEN\\\"\" --data-urlencode \"name=\$JF_NAME\" --data-urlencode \"collectionType=\$JF_TYPE\" --data-urlencode \"paths=\$JF_PATH\" --data-urlencode 'refreshLibrary=false' '${BASE_URL}/Library/VirtualFolders'" >/dev/null
}

verify_library() {
  local token="$1" name="$2"
  library_exists "${token}" "${name}" || {
    echo "ERROR: Jellyfin library '${name}' was not found after configuration."
    exit 1
  }
}

refresh_library() {
  local token="$1"
  docker compose exec -T -e JF_TOKEN="${token}" jellyfin sh -lc \
    "curl -fsS -X POST -H \"Authorization: MediaBrowser Token=\\\"\$JF_TOKEN\\\"\" '${BASE_URL}/Library/Refresh'" >/dev/null
}

wait_for_jellyfin
complete_startup_wizard
authenticate

create_library "${JELLYFIN_TOKEN}" "Movies"     "movies"     "${JELLYFIN_MOVIES_DIR}"
create_library "${JELLYFIN_TOKEN}" "TV Shows"   "tvshows"   "${JELLYFIN_TV_DIR}"
create_library "${JELLYFIN_TOKEN}" "Music"      "music"      "${JELLYFIN_MUSIC_DIR}"
create_library "${JELLYFIN_TOKEN}" "Audiobooks" "audiobooks" "${JELLYFIN_AUDIOBOOKS_DIR}"
create_library "${JELLYFIN_TOKEN}" "Books"      "books"      "${JELLYFIN_BOOKS_DIR}"

refresh_library "${JELLYFIN_TOKEN}"

path_exists "${JELLYFIN_MOVIES_DIR}"     && verify_library "${JELLYFIN_TOKEN}" "Movies"
path_exists "${JELLYFIN_TV_DIR}"         && verify_library "${JELLYFIN_TOKEN}" "TV Shows"
path_exists "${JELLYFIN_MUSIC_DIR}"      && verify_library "${JELLYFIN_TOKEN}" "Music"
path_exists "${JELLYFIN_AUDIOBOOKS_DIR}" && verify_library "${JELLYFIN_TOKEN}" "Audiobooks"
path_exists "${JELLYFIN_BOOKS_DIR}"      && verify_library "${JELLYFIN_TOKEN}" "Books"

echo "Done! Jellyfin admin and default libraries are configured."
