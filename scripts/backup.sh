#!/usr/bin/env bash
# Create a service-aware backup of configuration, app data, and database dumps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

BACKUP_ROOT="${BACKUP_ROOT:-./backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${1:-${BACKUP_ROOT}/${STAMP}}"

log() { echo "[backup] $*"; }
warn() { echo "[backup] WARNING: $*" >&2; }
has_docker() { command -v docker >/dev/null 2>&1; }

mkdir -p "${BACKUP_DIR}/db"

log "Writing manifest..."
{
  echo "created_utc=${STAMP}"
  echo "repo_dir=${REPO_DIR}"
  if has_docker; then
    docker compose version 2>/dev/null | sed 's/^/compose_version=/'
    docker compose images 2>/dev/null || true
  else
    echo "compose_version=unavailable"
  fi
} > "${BACKUP_DIR}/manifest.txt"

log "Saving project files..."
config_paths=(docker-compose.yml services.yml README.md ISSUES.md ROADMAP.md config scripts)
if [[ -f .env ]]; then
  config_paths=(.env "${config_paths[@]}")
else
  warn ".env not found; project-config archive will not include environment secrets"
fi
tar -czf "${BACKUP_DIR}/project-config.tgz" \
  --exclude='./backups' \
  --exclude='./data' \
  --exclude='./.git' \
  "${config_paths[@]}" 2>/dev/null

if [[ -d data ]]; then
  log "Saving data directory..."
  tar -czf "${BACKUP_DIR}/data.tgz" data
else
  warn "data directory does not exist; skipping data archive"
fi

if has_docker && docker compose ps postgres 2>/dev/null | grep -q 'postgres'; then
  log "Dumping PostgreSQL databases..."
  if ! docker compose exec -T postgres pg_dumpall -U postgres > "${BACKUP_DIR}/db/postgres.sql"; then
    warn "PostgreSQL dump failed"
    rm -f "${BACKUP_DIR}/db/postgres.sql"
  fi
else
  warn "PostgreSQL container is not available; skipping pg_dumpall"
fi

if has_docker && docker compose ps booklore-db 2>/dev/null | grep -q 'booklore-db'; then
  log "Dumping Booklore MariaDB database..."
  if ! docker compose exec -T booklore-db sh -lc 'mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases' > "${BACKUP_DIR}/db/booklore-mariadb.sql"; then
    warn "Booklore MariaDB dump failed"
    rm -f "${BACKUP_DIR}/db/booklore-mariadb.sql"
  fi
else
  warn "Booklore MariaDB container is not available; skipping mariadb-dump"
fi

log "Backup complete: ${BACKUP_DIR}"
