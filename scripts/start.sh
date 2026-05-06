#!/usr/bin/env bash
# Start the stack after checking Storage Box mount health.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

if [[ ! -f .env ]]; then
  echo -e "${RED}[FAIL]${NC}  .env not found. Run ./install.sh first."
  exit 1
fi

if [[ ! -r .env ]]; then
  echo -e "${RED}[FAIL]${NC}  .env is not readable by the current user."
  exit 1
fi

# shellcheck source=/dev/null
set -a; source .env; set +a

if [[ "${USE_STORAGE_BOX:-false}" == "true" ]]; then
  mount_ok=false

  if mountpoint -q "${STORAGEBOX_MOUNT}" 2>/dev/null; then
    if timeout 5 ls "${STORAGEBOX_MOUNT}/" >/dev/null 2>&1; then
      mount_ok=true
    else
      warn "Storage Box mount is stale; attempting remount..."
      umount -l "${STORAGEBOX_MOUNT}" 2>/dev/null || true
    fi
  fi

  if [[ "$mount_ok" == "false" ]]; then
    info "Storage Box not mounted; attempting to mount via fstab..."
    if mount "${STORAGEBOX_MOUNT}" 2>/dev/null; then
      sleep 2
      if timeout 5 ls "${STORAGEBOX_MOUNT}/" >/dev/null 2>&1; then
        mount_ok=true
        success "Storage Box remounted successfully"
      fi
    fi
  fi

  if [[ "$mount_ok" == "true" ]]; then
    export MEDIA_DIR="${STORAGEBOX_MOUNT}"
    export DOWNLOADS_DIR="${STORAGEBOX_MOUNT}/downloads"
    success "Storage Box healthy; using ${STORAGEBOX_MOUNT} for media"
  else
    export MEDIA_DIR="${MEDIA_DIR_LOCAL}"
    export DOWNLOADS_DIR="${DOWNLOADS_DIR_LOCAL}"
    echo ""
    echo -e "${YELLOW}${BOLD}  WARNING: Hetzner Storage Box is UNAVAILABLE${NC}"
    echo -e "${YELLOW}     Falling back to LOCAL storage for media and downloads.${NC}"
    echo -e "${YELLOW}     Any media on the Storage Box will NOT be visible until${NC}"
    echo -e "${YELLOW}     the Storage Box is remounted and the stack is restarted.${NC}"
    echo ""
    echo -e "     Remount:  ${CYAN}mount ${STORAGEBOX_MOUNT}${NC}"
    echo -e "     Restart:  ${CYAN}$(realpath "$0")${NC}"
    echo ""
  fi
fi

COMPOSE_FILES=(-f compose.core.yml -f compose.cloud.yml -f compose.media.yml -f compose.monitoring.yml -f compose.vpn.yml)
exec docker compose "${COMPOSE_FILES[@]}" up -d "$@"
