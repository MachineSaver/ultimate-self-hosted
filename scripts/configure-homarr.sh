#!/usr/bin/env bash
# Completes Homarr's OIDC first-run admin group setup.
# Called automatically by install.sh; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

if [[ -r .env ]]; then
  # shellcheck source=/dev/null
  set -a; source .env; set +a
elif [[ -f .env ]]; then
  echo "WARNING: .env exists but is not readable; using Homarr defaults that do not require secrets."
else
  echo "WARNING: .env not found; using Homarr defaults."
fi

HOMARR_ADMIN_GROUP="${HOMARR_ADMIN_GROUP:-homarr-admins}"
HOMARR_DB_PATH="${HOMARR_DB_PATH:-/appdata/db/db.sqlite}"

echo "Waiting for Homarr to be ready..."
retries=0
until docker exec homarr node -e \
  "fetch('http://localhost:7575/api/health/live').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
  2>/dev/null; do
  retries=$((retries+1))
  [[ $retries -gt 36 ]] && { echo "ERROR: Homarr did not become ready in 3 minutes."; exit 1; }
  sleep 5
done

echo "Configuring Homarr external admin group (${HOMARR_ADMIN_GROUP})..."
docker exec -i \
  -e HOMARR_ADMIN_GROUP="${HOMARR_ADMIN_GROUP}" \
  -e HOMARR_DB_PATH="${HOMARR_DB_PATH}" \
  homarr node - <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const Database = require('better-sqlite3');

const groupName = process.env.HOMARR_ADMIN_GROUP || 'homarr-admins';
const dbPath = process.env.HOMARR_DB_PATH || '/appdata/db/db.sqlite';

if (!fs.existsSync(dbPath)) {
  throw new Error(`Homarr database not found at ${dbPath}`);
}

const createId = () => crypto.randomBytes(12).toString('hex');
const db = new Database(dbPath);

const group = db.prepare('select id from "group" where lower(trim(name)) = lower(trim(?))').get(groupName);
const groupId = group?.id || createId();

const transaction = db.transaction(() => {
  if (!group) {
    const maxPosition = db.prepare('select coalesce(max(position), 0) as maxPosition from "group"').get().maxPosition;
    db.prepare('insert into "group" (id, name, position) values (?, ?, ?)').run(groupId, groupName, maxPosition + 1);
  }

  const adminPermission = db
    .prepare('select 1 from "groupPermission" where group_id = ? and permission = ?')
    .get(groupId, 'admin');
  if (!adminPermission) {
    db.prepare('insert into "groupPermission" (group_id, permission) values (?, ?)').run(groupId, 'admin');
  }

  const onboarding = db.prepare('select id from onboarding limit 1').get();
  if (onboarding) {
    db.prepare('update onboarding set step = ?, previous_step = ? where id = ?').run('finish', 'settings', onboarding.id);
  } else {
    db.prepare('insert into onboarding (id, step, previous_step) values (?, ?, ?)').run(createId(), 'finish', 'settings');
  }
});

transaction();

const verified = db
  .prepare(
    'select 1 from "group" g join "groupPermission" gp on gp.group_id = g.id where lower(trim(g.name)) = lower(trim(?)) and gp.permission = ?'
  )
  .get(groupName, 'admin');
if (!verified) {
  db.close();
  throw new Error(`Homarr admin group '${groupName}' was not verified after configuration`);
}

db.close();

console.log(`Homarr admin group '${groupName}' is configured and onboarding is complete.`);
NODE

docker restart homarr >/dev/null

echo "Done! Homarr OIDC first-run setup is configured."
