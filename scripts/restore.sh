#!/usr/bin/env bash
# Restore a backup created by scripts/backup.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

usage() {
  cat <<'EOF'
Usage: scripts/restore.sh --backup PATH --yes

Restores project config and data from a backup directory created by
scripts/backup.sh. This overwrites local .env, config, scripts, and data.

Options:
  --backup PATH  Backup directory to restore.
  --yes          Confirm destructive overwrite.
  -h, --help     Show this help.
EOF
}

BACKUP_DIR=""
CONFIRM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)
      BACKUP_DIR="${2:-}"
      shift 2
      ;;
    --yes)
      CONFIRM=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "${BACKUP_DIR}" ]] || { usage >&2; exit 2; }
[[ -d "${BACKUP_DIR}" ]] || { echo "Backup directory not found: ${BACKUP_DIR}" >&2; exit 1; }
[[ -f "${BACKUP_DIR}/project-config.tgz" ]] || { echo "Missing project-config.tgz in ${BACKUP_DIR}" >&2; exit 1; }
[[ "${CONFIRM}" == "true" ]] || { echo "Refusing to restore without --yes because this overwrites local state." >&2; exit 2; }

COMPOSE_FILES=(-f compose.core.yml -f compose.cloud.yml -f compose.media.yml -f compose.monitoring.yml -f compose.vpn.yml)

echo "[restore] Stopping stack..."
docker compose "${COMPOSE_FILES[@]}" down

echo "[restore] Restoring project config..."
tar -xzf "${BACKUP_DIR}/project-config.tgz"

if [[ -f "${BACKUP_DIR}/data.tgz" ]]; then
  echo "[restore] Restoring data directory..."
  rm -rf data
  tar -xzf "${BACKUP_DIR}/data.tgz"
else
  echo "[restore] WARNING: backup has no data.tgz; leaving data directory unchanged" >&2
fi

echo "[restore] Starting database containers..."
docker compose "${COMPOSE_FILES[@]}" up -d postgres booklore-db

if [[ -f "${BACKUP_DIR}/db/postgres.sql" ]]; then
  echo "[restore] Restoring PostgreSQL dump..."
  until docker compose "${COMPOSE_FILES[@]}" exec -T postgres pg_isready -U postgres >/dev/null 2>&1; do
    sleep 2
  done
  docker compose "${COMPOSE_FILES[@]}" exec -T postgres psql -U postgres < "${BACKUP_DIR}/db/postgres.sql"
fi

if [[ -f "${BACKUP_DIR}/db/booklore-mariadb.sql" ]]; then
  echo "[restore] Restoring Booklore MariaDB dump..."
  until docker compose "${COMPOSE_FILES[@]}" exec -T booklore-db mariadb-admin ping -h localhost >/dev/null 2>&1; do
    sleep 2
  done
  docker compose "${COMPOSE_FILES[@]}" exec -T booklore-db sh -lc 'mariadb -uroot -p"$MYSQL_ROOT_PASSWORD"' < "${BACKUP_DIR}/db/booklore-mariadb.sql"
elif [[ -f "${BACKUP_DIR}/db/booklore.sql" ]]; then
  echo "[restore] Restoring Booklore application database dump..."
  until docker compose "${COMPOSE_FILES[@]}" exec -T booklore-db mariadb-admin ping -h localhost >/dev/null 2>&1; do
    sleep 2
  done
  docker compose "${COMPOSE_FILES[@]}" exec -T booklore-db sh -lc 'mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' < "${BACKUP_DIR}/db/booklore.sql"
fi

echo "[restore] Restore complete. Start the full stack with ./scripts/start.sh."
