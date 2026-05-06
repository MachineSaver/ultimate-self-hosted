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

read_arr_api_key() {
  local container="$1"
  docker exec "${container}" sh -c \
    "sed -n 's:.*<ApiKey>\\(.*\\)</ApiKey>.*:\\1:p' /config/config.xml 2>/dev/null | head -n1" \
    2>/dev/null || true
}

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

echo "Applying Homarr Home board theme..."
docker exec -i \
  -e HOMARR_DB_PATH="${HOMARR_DB_PATH}" \
  homarr node - <<'NODE'
const fs = require('fs');
const Database = require('better-sqlite3');

const dbPath = process.env.HOMARR_DB_PATH || '/appdata/db/db.sqlite';
if (!fs.existsSync(dbPath)) throw new Error(`Homarr database not found at ${dbPath}`);

const db = new Database(dbPath);
const board = db.prepare("SELECT id FROM board WHERE name = 'Home'").get();
if (!board) {
  db.close();
  console.warn('WARNING: Home board not found — skipping theme.');
  process.exit(0);
}

const cols = db.prepare('PRAGMA table_info("board")').all().map(c => c.name);
const pick = (...candidates) => candidates.find(c => cols.includes(c));
const customCssCol = pick('custom_css', 'customCss');
const primaryCol = pick('primary_color', 'primaryColor');
const secondaryCol = pick('secondary_color', 'secondaryColor');
const opacityCol = pick('opacity');
const radiusCol = pick('item_radius', 'itemRadius');
const bgUrlCol = pick('background_image_url', 'backgroundImageUrl');
const bgAttachmentCol = pick('background_image_attachment', 'backgroundImageAttachment');
const bgRepeatCol = pick('background_image_repeat', 'backgroundImageRepeat');
const bgSizeCol = pick('background_image_size', 'backgroundImageSize');

if (!customCssCol) {
  db.close();
  throw new Error(`Table "board" has no custom CSS column. Found: ${cols.join(', ')}`);
}

const css = `
:root {
  --ush-surface: rgba(13, 18, 26, 0.62);
  --ush-surface-strong: rgba(13, 18, 26, 0.78);
  --ush-border: rgba(255, 255, 255, 0.18);
  --ush-text: #f8fafc;
  --ush-muted: #cbd5e1;
  --ush-accent: #38bdf8;
  --ush-accent-warm: #fb923c;
}

body {
  color: var(--ush-text);
  background:
    radial-gradient(circle at 18% 12%, rgba(56, 189, 248, 0.30), transparent 30rem),
    radial-gradient(circle at 86% 18%, rgba(251, 146, 60, 0.22), transparent 28rem),
    linear-gradient(135deg, #08111f 0%, #162032 48%, #0f172a 100%) !important;
}

.mantine-AppShell-header {
  background: var(--ush-surface-strong) !important;
  border-bottom: 1px solid var(--ush-border) !important;
  box-shadow: 0 18px 44px rgba(0, 0, 0, 0.24);
  backdrop-filter: blur(18px) saturate(150%);
}

.mantine-AppShell-main {
  background: transparent !important;
}

.grid-stack-item > .mantine-Card-root,
.mantine-Modal-content,
.mantine-Spotlight-content,
.mantine-Menu-dropdown,
.mantine-Popover-dropdown,
.mantine-Combobox-dropdown {
  background: var(--ush-surface) !important;
  border: 1px solid var(--ush-border) !important;
  box-shadow: 0 18px 44px rgba(0, 0, 0, 0.24);
  backdrop-filter: blur(18px) saturate(150%);
}

.grid-stack-item > .mantine-Card-root {
  transition: transform 150ms ease, border-color 150ms ease, box-shadow 150ms ease;
}

.grid-stack-item > .mantine-Card-root:hover {
  border-color: rgba(56, 189, 248, 0.50) !important;
  box-shadow: 0 22px 54px rgba(8, 17, 31, 0.34);
  transform: translateY(-1px);
}

.grid-stack-item > .mantine-Badge-root {
  background: linear-gradient(135deg, var(--ush-accent), var(--ush-accent-warm)) !important;
  color: #07111f !important;
  border: 0 !important;
  box-shadow: 0 10px 24px rgba(8, 17, 31, 0.28);
}

.mantine-Title-root,
.mantine-Text-root,
.mantine-Badge-label {
  color: inherit;
}

.mantine-Text-root {
  color: var(--ush-muted);
}

.mantine-ActionIcon-root,
.mantine-Button-root,
.mantine-Input-input {
  border-color: var(--ush-border) !important;
}

.mantine-ActionIcon-root:hover,
.mantine-Button-root:hover {
  border-color: rgba(56, 189, 248, 0.55) !important;
}
`.trim();

const assignments = [`"${customCssCol}" = ?`];
const values = [css];
if (primaryCol) {
  assignments.push(`"${primaryCol}" = ?`);
  values.push('#38bdf8');
}
if (secondaryCol) {
  assignments.push(`"${secondaryCol}" = ?`);
  values.push('#fb923c');
}
if (opacityCol) {
  assignments.push(`"${opacityCol}" = ?`);
  values.push(82);
}
if (radiusCol) {
  assignments.push(`"${radiusCol}" = ?`);
  values.push('md');
}
if (bgUrlCol) {
  assignments.push(`"${bgUrlCol}" = ?`);
  values.push(null);
}
if (bgAttachmentCol) {
  assignments.push(`"${bgAttachmentCol}" = ?`);
  values.push('fixed');
}
if (bgRepeatCol) {
  assignments.push(`"${bgRepeatCol}" = ?`);
  values.push('no-repeat');
}
if (bgSizeCol) {
  assignments.push(`"${bgSizeCol}" = ?`);
  values.push('cover');
}
values.push(board.id);

db.prepare(`UPDATE board SET ${assignments.join(', ')} WHERE id = ?`).run(...values);

const verified = db.prepare(`SELECT "${customCssCol}" AS css FROM board WHERE id = ?`).get(board.id);
db.close();

if (!verified?.css?.includes('--ush-surface')) {
  throw new Error('Homarr Home board theme was not verified after update');
}

console.log('Homarr Home board theme applied.');
NODE

echo "Ensuring Homarr Home board operations widgets..."
SONARR_API_KEY="${SONARR_API_KEY:-$(read_arr_api_key sonarr)}"
RADARR_API_KEY="${RADARR_API_KEY:-$(read_arr_api_key radarr)}"
LIDARR_API_KEY="${LIDARR_API_KEY:-$(read_arr_api_key lidarr)}"

JELLYFIN_API_KEY=""
if [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASSWORD:-}" ]]; then
  JELLYFIN_API_KEY=$(docker exec \
    -e ADMIN_USER="${ADMIN_USER}" \
    -e ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
    -i homarr node 2>/dev/null <<'JFKEY'
(async () => {
  try {
    const resp = await fetch('http://jellyfin:8096/Users/AuthenticateByName', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'MediaBrowser Client="ush", Device="installer", DeviceId="ush-homarr", Version="1.0"',
      },
      body: JSON.stringify({ Username: process.env.ADMIN_USER, Pw: process.env.ADMIN_PASSWORD }),
    });
    if (!resp.ok) return;
    const { AccessToken: token } = await resp.json();
    if (!token) return;
    const keysResp = await fetch('http://jellyfin:8096/Auth/Keys', {
      headers: { 'Authorization': 'MediaBrowser Token="' + token + '"' },
    });
    if (!keysResp.ok) return;
    const { Items: keys } = await keysResp.json();
    const key = keys?.find(k => k.AppName === 'ultimate-self-hosted-jellyfin-oidc');
    if (key) process.stdout.write(key.AccessToken);
  } catch {}
})();
JFKEY
  ) || true
fi

if [[ -z "${JELLYFIN_API_KEY}" ]]; then
  echo "WARNING: Could not retrieve Jellyfin API key — Jellyfin media server widget will be skipped."
fi

docker exec -i \
  -e ADMIN_USER="${ADMIN_USER:-}" \
  -e ADMIN_PASSWORD="${ADMIN_PASSWORD:-}" \
  -e HOMARR_SECRET_KEY="${HOMARR_SECRET_KEY:-}" \
  -e SONARR_API_KEY="${SONARR_API_KEY}" \
  -e RADARR_API_KEY="${RADARR_API_KEY}" \
  -e LIDARR_API_KEY="${LIDARR_API_KEY}" \
  -e JELLYFIN_API_KEY="${JELLYFIN_API_KEY}" \
  -e HOMARR_DB_PATH="${HOMARR_DB_PATH}" \
  homarr node - <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const Database = require('better-sqlite3');

const dbPath = process.env.HOMARR_DB_PATH || '/appdata/db/db.sqlite';
if (!fs.existsSync(dbPath)) throw new Error(`Homarr database not found at ${dbPath}`);

const adminUser = process.env.ADMIN_USER || '';
const adminPassword = process.env.ADMIN_PASSWORD || '';
const secretKey = process.env.HOMARR_SECRET_KEY || process.env.SECRET_ENCRYPTION_KEY || '';
const arrIntegrations = [
  { name: 'Sonarr', kind: 'sonarr', url: 'http://sonarr:8989', apiKey: process.env.SONARR_API_KEY || '' },
  { name: 'Radarr', kind: 'radarr', url: 'http://radarr:7878', apiKey: process.env.RADARR_API_KEY || '' },
  { name: 'Lidarr', kind: 'lidarr', url: 'http://lidarr:8686', apiKey: process.env.LIDARR_API_KEY || '' },
];
const jellyfinApiKey = process.env.JELLYFIN_API_KEY || '';

const newId = () => crypto.randomBytes(12).toString('hex');
const sj = obj => JSON.stringify({ json: obj });
const EMPTY = '{"json":{}}';
const encryptSecret = value => {
  if (!secretKey || !/^[a-fA-F0-9]{64}$/.test(secretKey)) {
    throw new Error('HOMARR_SECRET_KEY must be a 64-character hex value to seed integration secrets');
  }
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv('aes-256-cbc', Buffer.from(secretKey, 'hex'), iv);
  const encrypted = Buffer.concat([cipher.update(value), cipher.final()]);
  return `${encrypted.toString('hex')}.${iv.toString('hex')}`;
};

const db = new Database(dbPath);
const allTables = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r => r.name);
for (const t of ['board', 'section', 'item', 'layout', 'item_layout', 'section_layout']) {
  if (!allTables.includes(t)) throw new Error(`Required table "${t}" not found in Homarr DB.`);
}

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

const SC = { boardId: pick('section', 'board_id', 'boardId') };
const IC = {
  boardId: pick('item', 'board_id', 'boardId'),
  advOpts: pick('item', 'advanced_options', 'advancedOptions'),
};
const LC = { boardId: pick('layout', 'board_id', 'boardId') };
const ILC = {
  itemId: pick('item_layout', 'item_id', 'itemId'),
  sectionId: pick('item_layout', 'section_id', 'sectionId'),
  layoutId: pick('item_layout', 'layout_id', 'layoutId'),
  x: pick('item_layout', 'x_offset', 'xOffset'),
  y: pick('item_layout', 'y_offset', 'yOffset'),
};
const SLC = {
  sectionId: pick('section_layout', 'section_id', 'sectionId'),
  layoutId: pick('section_layout', 'layout_id', 'layoutId'),
  x: pick('section_layout', 'x_offset', 'xOffset'),
  y: pick('section_layout', 'y_offset', 'yOffset'),
};

const hasIntegrations = allTables.includes('integration') && allTables.includes('integration_item');
const hasIntegrationSecrets = allTables.includes('integrationSecret');
let INTC = null;
let IIC = null;
let ISC = null;
if (hasIntegrations) {
  INTC = {
    id: pick('integration', 'id'),
    name: pick('integration', 'name'),
    url: pick('integration', 'url'),
    kind: pick('integration', 'kind'),
  };
  IIC = {
    itemId: pick('integration_item', 'item_id', 'itemId'),
    integrationId: pick('integration_item', 'integration_id', 'integrationId'),
  };
}
if (hasIntegrationSecrets) {
  ISC = {
    kind: pick('integrationSecret', 'kind'),
    value: pick('integrationSecret', 'value'),
    updatedAt: pick('integrationSecret', 'updated_at', 'updatedAt'),
    integrationId: pick('integrationSecret', 'integration_id', 'integrationId'),
  };
}

const board = db.prepare("SELECT id FROM board WHERE name = 'Home'").get();
if (!board) {
  db.close();
  console.warn('WARNING: Home board not found - skipping operations widgets.');
  process.exit(0);
}

const layout = db.prepare(`SELECT id FROM layout WHERE ${Q(LC.boardId)} = ? AND name = 'default' ORDER BY breakpoint LIMIT 1`).get(board.id)
  || db.prepare(`SELECT id FROM layout WHERE ${Q(LC.boardId)} = ? ORDER BY breakpoint LIMIT 1`).get(board.id);
if (!layout) {
  db.close();
  console.warn('WARNING: Home board has no layout - skipping operations widgets.');
  process.exit(0);
}

const transaction = db.transaction(() => {
  let section = db.prepare(`SELECT id FROM section WHERE ${Q(SC.boardId)} = ? AND kind = 'category' AND name = 'Operations'`).get(board.id);
  if (!section) {
    section = { id: newId() };
    db.prepare(`
      INSERT INTO section (id, ${Q(SC.boardId)}, kind, name, options, x_offset, y_offset)
      VALUES (?, ?, 'category', 'Operations', ?, 0, 0)
    `).run(section.id, board.id, EMPTY);
  }

  const sectionLayout = db.prepare(
    `SELECT 1 FROM section_layout WHERE ${Q(SLC.sectionId)} = ? AND ${Q(SLC.layoutId)} = ?`
  ).get(section.id, layout.id);
  if (!sectionLayout) {
    db.prepare(`
      INSERT INTO section_layout (${Q(SLC.sectionId)}, ${Q(SLC.layoutId)}, ${Q(SLC.x)}, ${Q(SLC.y)}, width, height)
      VALUES (?, ?, 0, 12, 12, 16)
    `).run(section.id, layout.id);
  } else {
    db.prepare(`
      UPDATE section_layout SET width = 12, height = 16
      WHERE ${Q(SLC.sectionId)} = ? AND ${Q(SLC.layoutId)} = ?
    `).run(section.id, layout.id);
  }

  const ensureWidget = ({ kind, options, x, y, width, height, integrationId }) => {
    let item = db.prepare(`SELECT id FROM item WHERE ${Q(IC.boardId)} = ? AND kind = ?`).get(board.id, kind);
    if (!item) {
      item = { id: newId() };
      db.prepare(`
        INSERT INTO item (id, ${Q(IC.boardId)}, kind, options, ${Q(IC.advOpts)})
        VALUES (?, ?, ?, ?, ?)
      `).run(item.id, board.id, kind, sj(options), EMPTY);
    }

    const itemLayout = db.prepare(
      `SELECT 1 FROM item_layout WHERE ${Q(ILC.itemId)} = ? AND ${Q(ILC.sectionId)} = ? AND ${Q(ILC.layoutId)} = ?`
    ).get(item.id, section.id, layout.id);
    if (!itemLayout) {
      db.prepare(`
        INSERT INTO item_layout (${Q(ILC.itemId)}, ${Q(ILC.sectionId)}, ${Q(ILC.layoutId)},
          ${Q(ILC.x)}, ${Q(ILC.y)}, width, height)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      `).run(item.id, section.id, layout.id, x, y, width, height);
    }

    if (integrationId && hasIntegrations) {
      const linked = db.prepare(
        `SELECT 1 FROM integration_item WHERE ${Q(IIC.itemId)} = ? AND ${Q(IIC.integrationId)} = ?`
      ).get(item.id, integrationId);
      if (!linked) {
        db.prepare(`INSERT INTO integration_item (${Q(IIC.itemId)}, ${Q(IIC.integrationId)}) VALUES (?, ?)`)
          .run(item.id, integrationId);
      }
    }
  };

  ensureWidget({
    kind: 'dockerContainers',
    options: { enableRowSorting: true, defaultSort: 'name', descendingDefaultSort: false },
    x: 0,
    y: 0,
    width: 6,
    height: 4,
  });

  let glancesId = null;
  if (hasIntegrations) {
    const existing = db.prepare(`SELECT id FROM integration WHERE ${Q(INTC.kind)} = 'glances' AND ${Q(INTC.url)} = ?`)
      .get('http://glances:61208');
    glancesId = existing?.id || newId();
    if (!existing) {
      db.prepare(`
        INSERT INTO integration (${Q(INTC.id)}, ${Q(INTC.name)}, ${Q(INTC.url)}, ${Q(INTC.kind)})
        VALUES (?, 'Glances', 'http://glances:61208', 'glances')
      `).run(glancesId);
    }
  }

  const ensureIntegration = ({ name, kind, url, secrets }) => {
    const existing = db.prepare(`SELECT id FROM integration WHERE ${Q(INTC.kind)} = ? AND ${Q(INTC.url)} = ?`)
      .get(kind, url);
    const integrationId = existing?.id || newId();
    if (!existing) {
      db.prepare(`
        INSERT INTO integration (${Q(INTC.id)}, ${Q(INTC.name)}, ${Q(INTC.url)}, ${Q(INTC.kind)})
        VALUES (?, ?, ?, ?)
      `).run(integrationId, name, url, kind);
    }

    const upsertSecret = (kind, value) => {
      const existingSecret = db.prepare(
        `SELECT 1 FROM integrationSecret WHERE ${Q(ISC.integrationId)} = ? AND ${Q(ISC.kind)} = ?`
      ).get(integrationId, kind);
      const encrypted = encryptSecret(value);
      const updatedAt = Math.floor(Date.now() / 1000);
      if (existingSecret) {
        db.prepare(`
          UPDATE integrationSecret
          SET ${Q(ISC.value)} = ?, ${Q(ISC.updatedAt)} = ?
          WHERE ${Q(ISC.integrationId)} = ? AND ${Q(ISC.kind)} = ?
        `).run(encrypted, updatedAt, integrationId, kind);
      } else {
        db.prepare(`
          INSERT INTO integrationSecret (${Q(ISC.kind)}, ${Q(ISC.value)}, ${Q(ISC.updatedAt)}, ${Q(ISC.integrationId)})
          VALUES (?, ?, ?, ?)
        `).run(kind, encrypted, updatedAt, integrationId);
      }
    };
    for (const [kind, value] of Object.entries(secrets)) {
      upsertSecret(kind, value);
    }
    return integrationId;
  };

  let qbittorrentId = null;
  const arrIntegrationIds = [];
  if (hasIntegrations && hasIntegrationSecrets && adminUser && adminPassword) {
    qbittorrentId = ensureIntegration({
      name: 'qBittorrent',
      kind: 'qBittorrent',
      url: 'http://qbittorrent:8080',
      secrets: { username: adminUser, password: adminPassword },
    });
  } else if (!adminUser || !adminPassword) {
    console.warn('WARNING: ADMIN_USER or ADMIN_PASSWORD not set - skipping qBittorrent integration.');
  } else if (!hasIntegrationSecrets) {
    console.warn('WARNING: Homarr integrationSecret table not found - skipping qBittorrent integration.');
  }

  if (hasIntegrations && hasIntegrationSecrets) {
    for (const integration of arrIntegrations) {
      if (!integration.apiKey) {
        console.warn(`WARNING: ${integration.name} API key not found - skipping ${integration.name} calendar integration.`);
        continue;
      }
      arrIntegrationIds.push(ensureIntegration({
        name: integration.name,
        kind: integration.kind,
        url: integration.url,
        secrets: { apiKey: integration.apiKey },
      }));
    }
  }

  ensureWidget({
    kind: 'systemResources',
    options: { hasShadow: true, visibleCharts: ['cpu', 'memory', 'network'], labelDisplayMode: 'textWithIcon' },
    x: 6,
    y: 0,
    width: 6,
    height: 4,
    integrationId: glancesId,
  });

  ensureWidget({
    kind: 'downloads',
    options: {
      columns: ['integration', 'name', 'progress', 'time', 'downSpeed', 'upSpeed', 'actions'],
      enableRowSorting: true,
      defaultSort: 'added',
      descendingDefaultSort: true,
      showCompletedUsenet: false,
      showCompletedTorrent: true,
      showCompletedHttp: false,
      activeTorrentThreshold: 0,
      categoryFilter: [],
      filterIsWhitelist: false,
      applyFilterToRatio: true,
      limitPerIntegration: 20,
    },
    x: 0,
    y: 4,
    width: 12,
    height: 4,
    integrationId: qbittorrentId,
  });

  ensureWidget({
    kind: 'calendar',
    options: {
      releaseType: ['inCinemas', 'digitalRelease'],
      filterPastMonths: 2,
      filterFutureMonths: 3,
      showUnmonitored: false,
    },
    x: 0,
    y: 8,
    width: 12,
    height: 4,
  });
  const calendarItem = db.prepare(`SELECT id FROM item WHERE ${Q(IC.boardId)} = ? AND kind = 'calendar'`).get(board.id);
  if (calendarItem && hasIntegrations) {
    for (const integrationId of arrIntegrationIds) {
      const linked = db.prepare(
        `SELECT 1 FROM integration_item WHERE ${Q(IIC.itemId)} = ? AND ${Q(IIC.integrationId)} = ?`
      ).get(calendarItem.id, integrationId);
      if (!linked) {
        db.prepare(`INSERT INTO integration_item (${Q(IIC.itemId)}, ${Q(IIC.integrationId)}) VALUES (?, ?)`)
          .run(calendarItem.id, integrationId);
      }
    }
  }

  let jellyfinIntegrationId = null;
  if (hasIntegrations && hasIntegrationSecrets && jellyfinApiKey) {
    jellyfinIntegrationId = ensureIntegration({
      name: 'Jellyfin',
      kind: 'jellyfin',
      url: 'http://jellyfin:8096',
      secrets: { apiKey: jellyfinApiKey },
    });
  } else if (!jellyfinApiKey) {
    console.warn('WARNING: Jellyfin API key not available — skipping Jellyfin media server widget.');
  }

  ensureWidget({
    kind: 'mediaServer',
    options: { showOnlyPlaying: false },
    x: 0,
    y: 12,
    width: 12,
    height: 4,
    integrationId: jellyfinIntegrationId,
  });
});

transaction();

const dockerWidget = db.prepare(`SELECT 1 FROM item WHERE ${Q(IC.boardId)} = ? AND kind = 'dockerContainers'`).get(board.id);
const systemWidget = db.prepare(`SELECT 1 FROM item WHERE ${Q(IC.boardId)} = ? AND kind = 'systemResources'`).get(board.id);
const downloadsWidget = db.prepare(`SELECT 1 FROM item WHERE ${Q(IC.boardId)} = ? AND kind = 'downloads'`).get(board.id);
const calendarWidget = db.prepare(`SELECT 1 FROM item WHERE ${Q(IC.boardId)} = ? AND kind = 'calendar'`).get(board.id);
const mediaServerWidget = db.prepare(`SELECT 1 FROM item WHERE ${Q(IC.boardId)} = ? AND kind = 'mediaServer'`).get(board.id);
db.close();

if (!dockerWidget || !systemWidget || !downloadsWidget || !calendarWidget || !mediaServerWidget) {
  throw new Error('Homarr operations widgets were not verified after update');
}

console.log('Homarr Home board operations widgets configured.');
NODE

docker restart homarr >/dev/null

echo "Done! Homarr OIDC first-run setup is configured."
