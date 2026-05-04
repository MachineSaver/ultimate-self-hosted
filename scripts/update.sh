#!/usr/bin/env bash
# Pull configured image tags and redeploy after ensuring a recent backup exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

BACKUP_ROOT="${BACKUP_ROOT:-./backups}"
MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-24}"
SKIP_BACKUP_CHECK=false
CREATE_BACKUP=false

usage() {
  cat <<'EOF'
Usage: scripts/update.sh [--backup-first] [--skip-backup-check]

Options:
  --backup-first        Create a backup before pulling images.
  --skip-backup-check   Allow update without a recent backup.
  -h, --help            Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-first) CREATE_BACKUP=true ;;
    --skip-backup-check) SKIP_BACKUP_CHECK=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

latest_backup() {
  [[ -d "${BACKUP_ROOT}" ]] || return 0
  find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk 'NR == 1 {print $2}'
}

backup_is_recent() {
  local backup_dir="$1"
  [[ -n "${backup_dir}" ]] || return 1
  local now backup_mtime max_age
  now="$(date +%s)"
  backup_mtime="$(stat -c %Y "${backup_dir}")"
  max_age=$((MAX_BACKUP_AGE_HOURS * 3600))
  [[ $((now - backup_mtime)) -le ${max_age} ]]
}

if [[ "${CREATE_BACKUP}" == "true" ]]; then
  ./scripts/backup.sh
fi

if [[ "${SKIP_BACKUP_CHECK}" != "true" ]]; then
  backup_dir="$(latest_backup)"
  if ! backup_is_recent "${backup_dir}"; then
    echo "No backup newer than ${MAX_BACKUP_AGE_HOURS}h was found in ${BACKUP_ROOT}." >&2
    echo "Run scripts/update.sh --backup-first, or pass --skip-backup-check deliberately." >&2
    exit 1
  fi
  echo "[update] Using recent backup: ${backup_dir}"
fi

mkdir -p "${BACKUP_ROOT}/update-manifests"
manifest="${BACKUP_ROOT}/update-manifests/$(date -u +%Y%m%dT%H%M%SZ)-images.txt"

echo "[update] Recording current image state: ${manifest}"
docker compose images > "${manifest}" 2>/dev/null || true

echo "[update] Pulling configured image tags..."
docker compose pull

echo "[update] Recreating changed services..."
./scripts/start.sh

echo "[update] Update complete. Previous image state was recorded in ${manifest}."
