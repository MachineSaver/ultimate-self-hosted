#!/usr/bin/env bash
# Creates the Uptime Kuma admin account by writing db-config.json and
# updating the seeded SQLite database directly.
# Called automatically by install.sh; safe to re-run (UPDATE is idempotent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
# shellcheck source=/dev/null
set -a; source .env; set +a

# Uptime Kuma requires db-config.json to exist before it seeds kuma.db
# and skips the setup wizard. Write it if missing, then restart.
DB_CONFIG="./data/uptime-kuma/db-config.json"
if [[ ! -f "${DB_CONFIG}" ]]; then
  echo "Writing db-config.json..."
  mkdir -p "./data/uptime-kuma"
  echo '{"type":"sqlite"}' > "${DB_CONFIG}"
  echo "Restarting Uptime Kuma to apply db-config..."
  docker compose restart uptime-kuma
fi

echo "Waiting for Uptime Kuma to be ready..."
retries=0
until docker compose exec -T uptime-kuma node -e \
  "fetch('http://localhost:3001').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
  2>/dev/null; do
  retries=$((retries+1))
  [[ $retries -gt 36 ]] && { echo "ERROR: Uptime Kuma did not become ready in 3 minutes."; exit 1; }
  sleep 5
done

# Wait for kuma.db to be seeded from the bundled template
retries=0
until docker compose exec -T uptime-kuma test -f /app/data/kuma.db 2>/dev/null; do
  retries=$((retries+1))
  [[ $retries -gt 12 ]] && { echo "ERROR: kuma.db was not created in 1 minute."; exit 1; }
  sleep 5
done

echo "Configuring admin account..."
docker compose exec -T \
  -e UK_USER="${ADMIN_USER}" \
  -e UK_PASS="${ADMIN_PASSWORD}" \
  uptime-kuma node - << 'JSEOF'
const sqlite3 = require('@louislam/sqlite3');
const bcrypt = require('bcryptjs');
const { UK_USER, UK_PASS } = process.env;

const db = new sqlite3.Database('/app/data/kuma.db');

bcrypt.hash(UK_PASS, 10, (hashErr, hash) => {
  if (hashErr) {
    process.stderr.write('ERROR: bcrypt failed — ' + hashErr.message + '\n');
    process.exit(1);
  }

  db.get('SELECT COUNT(*) AS count FROM user', [], (cntErr, row) => {
    if (cntErr) {
      process.stderr.write('ERROR: DB query failed — ' + cntErr.message + '\n');
      db.close();
      process.exit(1);
    }

    if (row.count > 0) {
      db.run(
        'UPDATE user SET username = ?, password = ?, active = 1 WHERE id = 1',
        [UK_USER, hash],
        function (updErr) {
          db.close();
          if (updErr) {
            process.stderr.write('ERROR: UPDATE failed — ' + updErr.message + '\n');
            process.exit(1);
          }
          process.stdout.write('Admin account updated (' + UK_USER + ').\n');
        }
      );
    } else {
      db.run(
        'INSERT INTO user (username, password, active, timezone, language) VALUES (?, ?, 1, "UTC", "en")',
        [UK_USER, hash],
        function (insErr) {
          db.close();
          if (insErr) {
            process.stderr.write('ERROR: INSERT failed — ' + insErr.message + '\n');
            process.exit(1);
          }
          process.stdout.write('Admin account created (' + UK_USER + ').\n');
        }
      );
    }
  });
});
JSEOF

echo "Done! Uptime Kuma admin account configured (username: ${ADMIN_USER})."
