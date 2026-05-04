#!/usr/bin/env bash
# Validate repository, generated config, and optional runtime state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CHECK_NETWORK=false
CHECK_RUNTIME=false
SAMPLE_ENV=false

ok_count=0
warn_count=0
fail_count=0

usage() {
  cat <<'EOF'
Usage: scripts/doctor.sh [--network] [--runtime]

Checks static repository health by default.

Options:
  --network   Also validate DNS records for expected service subdomains.
  --runtime   Also inspect Docker daemon, containers, and Storage Box mount state.
  -h, --help  Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) CHECK_NETWORK=true ;;
    --runtime) CHECK_RUNTIME=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

pass() {
  ok_count=$((ok_count + 1))
  echo -e "${GREEN}[OK]${NC}    $*"
}

warn() {
  warn_count=$((warn_count + 1))
  echo -e "${YELLOW}[WARN]${NC}  $*"
}

fail() {
  fail_count=$((fail_count + 1))
  echo -e "${RED}[FAIL]${NC}  $*"
}

info() {
  echo -e "${CYAN}[INFO]${NC}  $*"
}

section() {
  echo ""
  echo -e "${BOLD}${CYAN}$*${NC}"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  if has_cmd "$1"; then
    pass "Command available: $1"
  else
    fail "Missing required command: $1"
  fi
}

warn_cmd() {
  if has_cmd "$1"; then
    pass "Optional command available: $1"
  else
    warn "Optional command unavailable: $1"
  fi
}

load_env() {
  if [[ -f .env ]]; then
    if [[ ! -r .env ]]; then
      SAMPLE_ENV=true
      fail ".env exists but is not readable by the current user; using sample values for static checks"
      set_sample_env
      return
    fi

    # shellcheck source=/dev/null
    set -a; source .env; set +a
    pass ".env exists and can be sourced"
  else
    SAMPLE_ENV=true
    warn ".env not found; using sample values for static checks"
    set_sample_env
  fi

  USE_STORAGE_BOX="${USE_STORAGE_BOX:-false}"
  STORAGEBOX_SHARE="${STORAGEBOX_SHARE:-backup}"
  STORAGEBOX_MOUNT="${STORAGEBOX_MOUNT:-/mnt/storagebox}"
}

set_sample_env() {
  DOMAIN="${DOMAIN:-example.com}"
  ADMIN_USER="${ADMIN_USER:-admin}"
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-change-me}"
  ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
  TZ="${TZ:-UTC}"
  PUID="${PUID:-1000}"
  PGID="${PGID:-1000}"
  MEDIA_DIR="${MEDIA_DIR:-./data/media}"
  DOWNLOADS_DIR="${DOWNLOADS_DIR:-./data/downloads}"
  MEDIA_DIR_LOCAL="${MEDIA_DIR_LOCAL:-./data/media}"
  DOWNLOADS_DIR_LOCAL="${DOWNLOADS_DIR_LOCAL:-./data/downloads}"
  USE_STORAGE_BOX="${USE_STORAGE_BOX:-false}"
  STORAGEBOX_HOST="${STORAGEBOX_HOST:-}"
  STORAGEBOX_USER="${STORAGEBOX_USER:-}"
  STORAGEBOX_SHARE="${STORAGEBOX_SHARE:-backup}"
  STORAGEBOX_MOUNT="${STORAGEBOX_MOUNT:-/mnt/storagebox}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-doctor-postgres}"
  REDIS_PASSWORD="${REDIS_PASSWORD:-doctor-redis}"
  NEXTCLOUD_DB_PASSWORD="${NEXTCLOUD_DB_PASSWORD:-doctor-nextcloud}"
  BOOKLORE_DB_PASSWORD="${BOOKLORE_DB_PASSWORD:-doctor-booklore}"
  BOOKLORE_DB_ROOT_PASSWORD="${BOOKLORE_DB_ROOT_PASSWORD:-doctor-booklore-root}"
  AUTHENTIK_SECRET_KEY="${AUTHENTIK_SECRET_KEY:-doctor-authentik-secret}"
  AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-doctor-authentik-token}"
  HOMARR_OIDC_CLIENT_ID="${HOMARR_OIDC_CLIENT_ID:-doctor-homarr}"
  HOMARR_OIDC_CLIENT_SECRET="${HOMARR_OIDC_CLIENT_SECRET:-doctor-homarr-secret}"
  HOMARR_SECRET_KEY="${HOMARR_SECRET_KEY:-doctor-homarr-key}"
  AUDIOBOOKSHELF_OIDC_CLIENT_ID="${AUDIOBOOKSHELF_OIDC_CLIENT_ID:-doctor-abs}"
  AUDIOBOOKSHELF_OIDC_CLIENT_SECRET="${AUDIOBOOKSHELF_OIDC_CLIENT_SECRET:-doctor-abs-secret}"
  JELLYFIN_OIDC_CLIENT_ID="${JELLYFIN_OIDC_CLIENT_ID:-doctor-jellyfin}"
  JELLYFIN_OIDC_CLIENT_SECRET="${JELLYFIN_OIDC_CLIENT_SECRET:-doctor-jellyfin-secret}"
  NEXTCLOUD_OIDC_CLIENT_ID="${NEXTCLOUD_OIDC_CLIENT_ID:-doctor-nextcloud}"
  NEXTCLOUD_OIDC_CLIENT_SECRET="${NEXTCLOUD_OIDC_CLIENT_SECRET:-doctor-nextcloud-secret}"
  GRAFANA_OIDC_CLIENT_ID="${GRAFANA_OIDC_CLIENT_ID:-doctor-grafana}"
  GRAFANA_OIDC_CLIENT_SECRET="${GRAFANA_OIDC_CLIENT_SECRET:-doctor-grafana-secret}"
  VAULTWARDEN_OIDC_CLIENT_ID="${VAULTWARDEN_OIDC_CLIENT_ID:-doctor-vaultwarden}"
  VAULTWARDEN_OIDC_CLIENT_SECRET="${VAULTWARDEN_OIDC_CLIENT_SECRET:-doctor-vaultwarden-secret}"
}

env_or_sample() {
  cat > "$1" <<EOF
DOMAIN=${DOMAIN:-example.com}
ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-change-me}
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@example.com}
TZ=${TZ:-UTC}
PUID=${PUID:-1000}
PGID=${PGID:-1000}
MEDIA_DIR=${MEDIA_DIR:-./data/media}
DOWNLOADS_DIR=${DOWNLOADS_DIR:-./data/downloads}
MEDIA_DIR_LOCAL=${MEDIA_DIR_LOCAL:-./data/media}
DOWNLOADS_DIR_LOCAL=${DOWNLOADS_DIR_LOCAL:-./data/downloads}
USE_STORAGE_BOX=${USE_STORAGE_BOX:-false}
STORAGEBOX_HOST=${STORAGEBOX_HOST:-}
STORAGEBOX_USER=${STORAGEBOX_USER:-}
STORAGEBOX_SHARE=${STORAGEBOX_SHARE:-backup}
STORAGEBOX_MOUNT=${STORAGEBOX_MOUNT:-/mnt/storagebox}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-doctor-postgres}
REDIS_PASSWORD=${REDIS_PASSWORD:-doctor-redis}
NEXTCLOUD_DB_PASSWORD=${NEXTCLOUD_DB_PASSWORD:-doctor-nextcloud}
BOOKLORE_DB_PASSWORD=${BOOKLORE_DB_PASSWORD:-doctor-booklore}
BOOKLORE_DB_ROOT_PASSWORD=${BOOKLORE_DB_ROOT_PASSWORD:-doctor-booklore-root}
AUTHENTIK_SECRET_KEY=${AUTHENTIK_SECRET_KEY:-doctor-authentik-secret}
AUTHENTIK_BOOTSTRAP_TOKEN=${AUTHENTIK_BOOTSTRAP_TOKEN:-doctor-authentik-token}
HOMARR_OIDC_CLIENT_ID=${HOMARR_OIDC_CLIENT_ID:-doctor-homarr}
HOMARR_OIDC_CLIENT_SECRET=${HOMARR_OIDC_CLIENT_SECRET:-doctor-homarr-secret}
HOMARR_SECRET_KEY=${HOMARR_SECRET_KEY:-doctor-homarr-key}
AUDIOBOOKSHELF_OIDC_CLIENT_ID=${AUDIOBOOKSHELF_OIDC_CLIENT_ID:-doctor-abs}
AUDIOBOOKSHELF_OIDC_CLIENT_SECRET=${AUDIOBOOKSHELF_OIDC_CLIENT_SECRET:-doctor-abs-secret}
JELLYFIN_OIDC_CLIENT_ID=${JELLYFIN_OIDC_CLIENT_ID:-doctor-jellyfin}
JELLYFIN_OIDC_CLIENT_SECRET=${JELLYFIN_OIDC_CLIENT_SECRET:-doctor-jellyfin-secret}
NEXTCLOUD_OIDC_CLIENT_ID=${NEXTCLOUD_OIDC_CLIENT_ID:-doctor-nextcloud}
NEXTCLOUD_OIDC_CLIENT_SECRET=${NEXTCLOUD_OIDC_CLIENT_SECRET:-doctor-nextcloud-secret}
GRAFANA_OIDC_CLIENT_ID=${GRAFANA_OIDC_CLIENT_ID:-doctor-grafana}
GRAFANA_OIDC_CLIENT_SECRET=${GRAFANA_OIDC_CLIENT_SECRET:-doctor-grafana-secret}
VAULTWARDEN_OIDC_CLIENT_ID=${VAULTWARDEN_OIDC_CLIENT_ID:-doctor-vaultwarden}
VAULTWARDEN_OIDC_CLIENT_SECRET=${VAULTWARDEN_OIDC_CLIENT_SECRET:-doctor-vaultwarden-secret}
EOF
}

check_required_env() {
  local missing=()
  local required=(
    DOMAIN ADMIN_USER ADMIN_PASSWORD ADMIN_EMAIL TZ PUID PGID
    MEDIA_DIR DOWNLOADS_DIR POSTGRES_PASSWORD REDIS_PASSWORD
    AUTHENTIK_SECRET_KEY AUTHENTIK_BOOTSTRAP_TOKEN
    HOMARR_OIDC_CLIENT_ID HOMARR_OIDC_CLIENT_SECRET HOMARR_SECRET_KEY
    AUDIOBOOKSHELF_OIDC_CLIENT_ID AUDIOBOOKSHELF_OIDC_CLIENT_SECRET
    JELLYFIN_OIDC_CLIENT_ID JELLYFIN_OIDC_CLIENT_SECRET
    NEXTCLOUD_OIDC_CLIENT_ID NEXTCLOUD_OIDC_CLIENT_SECRET NEXTCLOUD_DB_PASSWORD
    GRAFANA_OIDC_CLIENT_ID GRAFANA_OIDC_CLIENT_SECRET
    VAULTWARDEN_OIDC_CLIENT_ID VAULTWARDEN_OIDC_CLIENT_SECRET
    BOOKLORE_DB_PASSWORD BOOKLORE_DB_ROOT_PASSWORD
  )

  for key in "${required[@]}"; do
    if [[ -z "${!key:-}" ]]; then
      missing+=("$key")
    fi
  done

  if [[ "$SAMPLE_ENV" == "true" ]]; then
    pass "Sample environment variables are available for static checks"
  elif [[ ${#missing[@]} -eq 0 ]]; then
    pass "Required environment variables are present"
  else
    fail "Missing required environment variables: ${missing[*]}"
  fi
}

check_bash_syntax() {
  local failed=0
  while IFS= read -r script; do
    if bash -n "$script"; then
      :
    else
      failed=1
    fi
  done < <(find install.sh scripts -name '*.sh' -type f -print)

  if [[ "$failed" -eq 0 ]]; then
    pass "Shell scripts pass bash syntax checks"
  else
    fail "One or more shell scripts failed bash syntax checks"
  fi
}

check_template_placeholders() {
  local generated_with_placeholders
  generated_with_placeholders=$(find config -type f ! -name '*.template' -print0 \
    | xargs -0 grep -n '{{[A-Z0-9_]*}}' 2>/dev/null || true)

  if [[ -z "$generated_with_placeholders" ]]; then
    pass "No unreplaced placeholders found in generated config files"
  else
    fail "Unreplaced placeholders found in generated config files"
    echo "$generated_with_placeholders"
  fi
}

check_templates_exist() {
  local count
  count=$(find config -name '*.template' -type f | wc -l | tr -d ' ')
  if [[ "$count" -gt 0 ]]; then
    pass "Template files found: $count"
  else
    fail "No config templates found"
  fi
}

check_service_registry() {
  if [[ ! -f services.yml ]]; then
    fail "services.yml is missing"
    return
  fi

  local count missing_scripts
  count=$(grep -c '^[[:space:]]*- name:' services.yml || true)
  missing_scripts=$(
    awk '/post_install_script:/ {print $2}' services.yml \
      | while read -r script; do
          [[ -f "$script" ]] || echo "$script"
        done
  )

  if [[ "$count" -lt 15 ]]; then
    fail "services.yml appears incomplete: ${count} services listed"
  elif [[ -n "$missing_scripts" ]]; then
    fail "services.yml references missing post-install scripts:"
    echo "$missing_scripts"
  else
    pass "Service registry is present and references existing scripts"
  fi
}

check_compose_config() {
  if ! has_cmd docker; then
    fail "Cannot validate Compose config because docker is unavailable"
    return
  fi

  local env_file
  env_file="$(mktemp)"
  env_or_sample "$env_file"

  if docker compose --env-file "$env_file" config >/tmp/ultimate-self-hosted-compose-config.yml 2>/tmp/ultimate-self-hosted-compose-config.err; then
    pass "Docker Compose config renders"
  else
    fail "Docker Compose config failed to render"
    sed -n '1,80p' /tmp/ultimate-self-hosted-compose-config.err
  fi

  rm -f "$env_file"
}

check_no_latest_images() {
  local latest
  latest=$(grep -nE 'image: .+:(latest|2)$' docker-compose.yml || true)
  if [[ -z "$latest" ]]; then
    pass "Compose images do not use floating latest tags"
  else
    warn "Floating image tags found"
    echo "$latest"
  fi
}

check_executable_scripts() {
  local non_exec
  non_exec=$(find scripts -name '*.sh' -type f ! -perm -111 -print)
  if [[ -z "$non_exec" ]]; then
    pass "All scripts/*.sh files are executable"
  else
    fail "Scripts missing executable bit:"
    echo "$non_exec"
  fi
}

check_ports() {
  local ports=(80 443)
  local port busy=0

  if ! has_cmd ss; then
    warn "Cannot inspect local TCP ports because ss is unavailable"
    return
  fi

  for port in "${ports[@]}"; do
    local output
    if ! output=$(ss -H -ltn "sport = :${port}" 2>&1); then
      warn "Cannot inspect TCP port ${port}: ${output}"
      continue
    fi
    if grep -q . <<< "$output"; then
      warn "TCP port ${port} is already listening"
      busy=1
    fi
  done

  if [[ "$busy" -eq 0 ]]; then
    pass "Required TCP ports 80 and 443 are not currently listening"
  fi
}

check_dns() {
  local subdomains=(
    home auth jellyfin requests audiobooks books music sonarr radarr lidarr
    prowlarr qbit cloud headscale vpn uptime grafana vault traefik
  )
  local failed=0
  local host

  if [[ -z "${DOMAIN:-}" || "${DOMAIN}" == "example.com" ]]; then
    warn "Skipping DNS checks because DOMAIN is not configured"
    return
  fi

  if ! has_cmd getent; then
    warn "Cannot run DNS checks because getent is unavailable"
    return
  fi

  for subdomain in "${subdomains[@]}"; do
    host="${subdomain}.${DOMAIN}"
    if ! getent ahosts "$host" >/dev/null; then
      warn "DNS lookup failed: $host"
      failed=1
    fi
  done

  if [[ "$failed" -eq 0 ]]; then
    pass "DNS records resolved for expected service subdomains"
  fi
}

check_docker_runtime() {
  if ! docker info >/dev/null 2>&1; then
    fail "Docker daemon is not reachable"
    return
  fi
  pass "Docker daemon is reachable"

  if docker compose ps >/tmp/ultimate-self-hosted-compose-ps.txt 2>/tmp/ultimate-self-hosted-compose-ps.err; then
    pass "Docker Compose runtime state is readable"
  else
    warn "Docker Compose runtime state is not available yet"
    sed -n '1,80p' /tmp/ultimate-self-hosted-compose-ps.err
  fi
}

check_storage_runtime() {
  if [[ "${USE_STORAGE_BOX:-false}" != "true" ]]; then
    pass "Storage Box disabled; mount health check not required"
    return
  fi

  if [[ -z "${STORAGEBOX_MOUNT:-}" ]]; then
    fail "USE_STORAGE_BOX=true but STORAGEBOX_MOUNT is empty"
    return
  fi

  if mountpoint -q "${STORAGEBOX_MOUNT}" 2>/dev/null && timeout 5 ls "${STORAGEBOX_MOUNT}/" >/dev/null 2>&1; then
    pass "Storage Box mount is reachable: ${STORAGEBOX_MOUNT}"
  else
    fail "Storage Box mount is not healthy: ${STORAGEBOX_MOUNT}"
  fi
}

echo -e "${BOLD}Ultimate Self-Hosted Doctor${NC}"

section "Repository Checks"
require_cmd docker
require_cmd curl
require_cmd openssl
warn_cmd shellcheck
check_templates_exist
check_bash_syntax
check_executable_scripts
check_template_placeholders
check_no_latest_images
check_service_registry

section "Environment And Compose"
load_env
check_required_env
check_compose_config
check_ports

if [[ "$CHECK_NETWORK" == "true" ]]; then
  section "Network Checks"
  check_dns
else
  info "Skipping DNS checks; pass --network to enable them"
fi

if [[ "$CHECK_RUNTIME" == "true" ]]; then
  section "Runtime Checks"
  check_docker_runtime
  check_storage_runtime
else
  info "Skipping runtime checks; pass --runtime to enable them"
fi

echo ""
echo -e "${BOLD}Summary:${NC} ${GREEN}${ok_count} ok${NC}, ${YELLOW}${warn_count} warnings${NC}, ${RED}${fail_count} failures${NC}"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
