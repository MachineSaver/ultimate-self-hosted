#!/usr/bin/env bash
# Completes Homarr's OIDC first-run admin group setup and seeds the Home board.
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

echo "Seeding Homarr Home board..."
docker exec -i \
  -e DOMAIN="${DOMAIN:-}" \
  -e HOMARR_ADMIN_GROUP="${HOMARR_ADMIN_GROUP}" \
  -e HOMARR_DB_PATH="${HOMARR_DB_PATH}" \
  homarr node - <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const Database = require('better-sqlite3');

const domain    = process.env.DOMAIN || '';
const groupName = process.env.HOMARR_ADMIN_GROUP || 'homarr-admins';
const dbPath    = process.env.HOMARR_DB_PATH || '/appdata/db/db.sqlite';

if (!fs.existsSync(dbPath)) throw new Error(`Homarr database not found at ${dbPath}`);

if (!domain) {
  console.warn('WARNING: DOMAIN not set — skipping Home board seed.');
  process.exit(0);
}

const newId = () => crypto.randomBytes(12).toString('hex');
const sj    = obj => JSON.stringify({ json: obj });
const EMPTY = '{"json":{}}';
const ICON  = 'https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png';

const db = new Database(dbPath);

// PRAGMA-based column detection: handles camelCase and snake_case schemas
const tableInfo = {};
const cols = t => {
  if (!tableInfo[t]) {
    tableInfo[t] = db.prepare(`PRAGMA table_info("${t}")`).all().map(c => c.name);
  }
  return tableInfo[t];
};
const pick = (table, ...candidates) => {
  const c = cols(table);
  for (const cand of candidates) if (c.includes(cand)) return cand;
  throw new Error(`Table "${table}" missing all of [${candidates.join(', ')}]. Found: ${c.join(', ')}`);
};
const Q = c => `"${c}"`;

// Verify required tables exist
const allTables = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r => r.name);
for (const t of ['board', 'section', 'item', 'app', 'layout', 'item_layout', 'section_layout']) {
  if (!allTables.includes(t)) throw new Error(`Required table "${t}" not found in Homarr DB.`);
}

// Idempotency: skip if Home board already exists
if (db.prepare("SELECT 1 FROM board WHERE name = 'Home'").get()) {
  db.close();
  console.log('Home board already exists — skipping seed.');
  process.exit(0);
}

// Detect column names (camelCase or snake_case)
const BC = {
  isPublic:  pick('board', 'is_public',                   'isPublic'),
  imgAttach: pick('board', 'background_image_attachment', 'backgroundImageAttachment'),
  imgRepeat: pick('board', 'background_image_repeat',     'backgroundImageRepeat'),
  imgSize:   pick('board', 'background_image_size',       'backgroundImageSize'),
  primary:   pick('board', 'primary_color',               'primaryColor'),
  secondary: pick('board', 'secondary_color',             'secondaryColor'),
  radius:    pick('board', 'item_radius',                 'itemRadius'),
  disStatus: pick('board', 'disable_status',              'disableStatus'),
};
const LC = {
  boardId:     pick('layout', 'board_id',     'boardId'),
  columnCount: pick('layout', 'column_count', 'columnCount'),
};
const SC = {
  boardId: pick('section', 'board_id', 'boardId'),
};
const IC = {
  boardId: pick('item', 'board_id',        'boardId'),
  advOpts: pick('item', 'advanced_options', 'advancedOptions'),
};
const AC = {
  iconUrl: pick('app', 'icon_url', 'iconUrl'),
  pingUrl: pick('app', 'ping_url', 'pingUrl'),
};
const ILC = {
  itemId:    pick('item_layout', 'item_id',    'itemId'),
  sectionId: pick('item_layout', 'section_id', 'sectionId'),
  layoutId:  pick('item_layout', 'layout_id',  'layoutId'),
  x:         pick('item_layout', 'x_offset',   'xOffset'),
  y:         pick('item_layout', 'y_offset',   'yOffset'),
};
const SLC = {
  sectionId: pick('section_layout', 'section_id', 'sectionId'),
  layoutId:  pick('section_layout', 'layout_id',  'layoutId'),
  x:         pick('section_layout', 'x_offset',   'xOffset'),
  y:         pick('section_layout', 'y_offset',   'yOffset'),
};

const hasBGP = allTables.includes('boardGroupPermission');
let BGPC = null;
if (hasBGP) {
  BGPC = {
    boardId: pick('boardGroupPermission', 'board_id', 'boardId'),
    groupId: pick('boardGroupPermission', 'group_id', 'groupId'),
  };
}

const groupCols = cols('group');
const groupHomeCol = groupCols.includes('home_board_id') ? 'home_board_id'
                   : groupCols.includes('homeBoardId')   ? 'homeBoardId'
                   : null;

// Board layout: 12 columns, items 2×2, sections grouped by category
// Row 0–2: Media (full width)
// Row 3–5: Automation & Downloads (full width)
// Row 6–8: Cloud & Security (left half) | Network & VPN (right half)
// Row 9–11: Monitoring (left half) | Identity (right half)
const categories = [
  {
    name: 'Media', x: 0, y: 0, w: 12, h: 3,
    apps: [
      { name: 'Jellyfin',       icon: 'jellyfin',       href: `https://jellyfin.${domain}`   },
      { name: 'Navidrome',      icon: 'navidrome',      href: `https://music.${domain}`       },
      { name: 'Audiobookshelf', icon: 'audiobookshelf', href: `https://audiobooks.${domain}` },
      { name: 'Booklore',       icon: 'booklore',       href: `https://books.${domain}`       },
      { name: 'Jellyseerr',     icon: 'jellyseerr',     href: `https://requests.${domain}`   },
    ],
  },
  {
    name: 'Automation & Downloads', x: 0, y: 3, w: 12, h: 3,
    apps: [
      { name: 'Sonarr',      icon: 'sonarr',      href: `https://sonarr.${domain}`   },
      { name: 'Radarr',      icon: 'radarr',      href: `https://radarr.${domain}`   },
      { name: 'Lidarr',      icon: 'lidarr',      href: `https://lidarr.${domain}`   },
      { name: 'Prowlarr',    icon: 'prowlarr',    href: `https://prowlarr.${domain}` },
      { name: 'qBittorrent', icon: 'qbittorrent', href: `https://qbit.${domain}`     },
    ],
  },
  {
    name: 'Cloud & Security', x: 0, y: 6, w: 6, h: 3,
    apps: [
      { name: 'Nextcloud',   icon: 'nextcloud',   href: `https://cloud.${domain}` },
      { name: 'Vaultwarden', icon: 'vaultwarden', href: `https://vault.${domain}` },
    ],
  },
  {
    name: 'Network & VPN', x: 6, y: 6, w: 6, h: 3,
    apps: [
      { name: 'Headscale',  icon: 'headscale',  href: `https://headscale.${domain}` },
      { name: 'WireGuard',  icon: 'wireguard',  href: `https://vpn.${domain}`       },
      { name: 'Traefik',    icon: 'traefik',    href: `https://traefik.${domain}`   },
    ],
  },
  {
    name: 'Monitoring', x: 0, y: 9, w: 6, h: 3,
    apps: [
      { name: 'Uptime Kuma', icon: 'uptime-kuma', href: `https://uptime.${domain}`  },
      { name: 'Grafana',     icon: 'grafana',     href: `https://grafana.${domain}` },
    ],
  },
  {
    name: 'Identity', x: 6, y: 9, w: 6, h: 3,
    apps: [
      { name: 'Authentik', icon: 'authentik', href: `https://auth.${domain}` },
    ],
  },
];

db.transaction(() => {
  const boardId = newId();

  db.prepare(`
    INSERT INTO board (id, name, ${Q(BC.isPublic)}, ${Q(BC.imgAttach)}, ${Q(BC.imgRepeat)},
      ${Q(BC.imgSize)}, ${Q(BC.primary)}, ${Q(BC.secondary)}, opacity, ${Q(BC.radius)}, ${Q(BC.disStatus)})
    VALUES (?, 'Home', 1, 'fixed', 'no-repeat', 'cover', '#fa5252', '#fd7e14', 100, 'lg', 0)
  `).run(boardId);

  const layoutId = newId();
  db.prepare(`
    INSERT INTO layout (id, name, ${Q(LC.boardId)}, ${Q(LC.columnCount)}, breakpoint)
    VALUES (?, 'default', ?, 12, 0)
  `).run(layoutId, boardId);

  for (const cat of categories) {
    const sectionId = newId();
    db.prepare(`
      INSERT INTO section (id, ${Q(SC.boardId)}, kind, name, options, x_offset, y_offset)
      VALUES (?, ?, 'category', ?, ?, 0, 0)
    `).run(sectionId, boardId, cat.name, EMPTY);

    db.prepare(`
      INSERT INTO section_layout (${Q(SLC.sectionId)}, ${Q(SLC.layoutId)}, ${Q(SLC.x)}, ${Q(SLC.y)}, width, height)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(sectionId, layoutId, cat.x, cat.y, cat.w, cat.h);

    cat.apps.forEach((app, idx) => {
      const appId = newId();
      db.prepare(`
        INSERT INTO app (id, name, ${Q(AC.iconUrl)}, href, ${Q(AC.pingUrl)})
        VALUES (?, ?, ?, ?, ?)
      `).run(appId, app.name, `${ICON}/${app.icon}.png`, app.href, app.href);

      const itemId = newId();
      db.prepare(`
        INSERT INTO item (id, ${Q(IC.boardId)}, kind, options, ${Q(IC.advOpts)})
        VALUES (?, ?, 'app', ?, ?)
      `).run(itemId, boardId, sj({ appId }), EMPTY);

      db.prepare(`
        INSERT INTO item_layout (${Q(ILC.itemId)}, ${Q(ILC.sectionId)}, ${Q(ILC.layoutId)},
          ${Q(ILC.x)}, ${Q(ILC.y)}, width, height)
        VALUES (?, ?, ?, ?, ?, 2, 2)
      `).run(itemId, sectionId, layoutId, idx * 2, 0);
    });
  }

  // Set board as home for admin group and grant full access
  const group = db.prepare(`SELECT id FROM "group" WHERE lower(trim(name)) = lower(trim(?))`).get(groupName);
  if (!group) {
    console.warn(`WARNING: group "${groupName}" not found — home board not assigned.`);
    return;
  }

  if (groupHomeCol) {
    db.prepare(`UPDATE "group" SET ${Q(groupHomeCol)} = ? WHERE id = ?`).run(boardId, group.id);
  }

  if (hasBGP && BGPC) {
    const already = db.prepare(
      `SELECT 1 FROM "boardGroupPermission" WHERE ${Q(BGPC.boardId)} = ? AND ${Q(BGPC.groupId)} = ?`
    ).get(boardId, group.id);
    if (!already) {
      db.prepare(
        `INSERT INTO "boardGroupPermission" (${Q(BGPC.boardId)}, ${Q(BGPC.groupId)}, permission) VALUES (?, ?, 'full')`
      ).run(boardId, group.id);
    }
  }

  // Set global default home board in serverSetting
  const ssCols = db.prepare("PRAGMA table_info(serverSetting)").all().map(c => c.name);
  if (ssCols.includes('setting_key') && ssCols.includes('value')) {
    const ss = db.prepare("SELECT value FROM serverSetting WHERE setting_key = 'board'").get();
    if (ss) {
      const val = JSON.parse(ss.value);
      val.json = val.json || {};
      val.json.homeBoardId = boardId;
      db.prepare("UPDATE serverSetting SET value = ? WHERE setting_key = 'board'").run(JSON.stringify(val));
    }
  }

  // Apply home board to any existing users that don't have one yet
  const userCols = db.prepare("PRAGMA table_info(user)").all().map(c => c.name);
  const userHomeCol = userCols.includes('home_board_id') ? 'home_board_id'
                    : userCols.includes('homeBoardId')   ? 'homeBoardId'
                    : null;
  if (userHomeCol) {
    db.prepare(`UPDATE "user" SET ${Q(userHomeCol)} = ? WHERE ${Q(userHomeCol)} IS NULL`).run(boardId);
  }
})();

db.close();
console.log('Home board seeded with all services.');
NODE

docker restart homarr >/dev/null

echo "Done! Homarr OIDC first-run setup is configured."
