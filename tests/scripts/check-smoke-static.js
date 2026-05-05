#!/usr/bin/env node
'use strict';

/**
 * Static smoke suite validator — runs in CI without a live stack or browser.
 *
 * Checks:
 *   1. Every expected spec file is present on disk.
 *   2. helpers.js loads and exports the full expected API surface.
 *   3. global-setup.js loads and exports the expected functions.
 *
 * Add a new entry to EXPECTED_SPECS whenever a new service is added to the
 * stack so CI catches the missing test immediately.
 */

const fs   = require('fs');
const path = require('path');

const SMOKE_DIR = path.join(__dirname, '..', 'smoke');
let failures = 0;

function pass(msg) { console.log(`  ✓ ${msg}`); }
function fail(msg) { console.error(`  ✗ ${msg}`); failures++; }
function section(title) { console.log(`\n${title}`); }

// ---------------------------------------------------------------------------
// 1. Spec file inventory
// ---------------------------------------------------------------------------
section('Spec file inventory');

const EXPECTED_SPECS = [
  '01-authentik.spec.js',
  '02-homarr.spec.js',
  '03-jellyfin.spec.js',
  '04-jellyseerr.spec.js',
  '05-nextcloud.spec.js',
  '06-audiobookshelf.spec.js',
  '07-grafana.spec.js',
  '08-vaultwarden.spec.js',
  '09-qbittorrent.spec.js',
  '10-arr-stack.spec.js',
  '11-navidrome.spec.js',
  '12-uptime-kuma.spec.js',
  '13-wireguard.spec.js',
  '14-headscale.spec.js',
  '15-booklore.spec.js',
];

for (const f of EXPECTED_SPECS) {
  const full = path.join(SMOKE_DIR, f);
  if (fs.existsSync(full)) {
    pass(`${f} exists`);
  } else {
    fail(`${f} is missing — add a smoke test for this service`);
  }
}

// Warn about unlisted spec files so new services don't go unnoticed
const found = fs.readdirSync(SMOKE_DIR).filter(f => f.endsWith('.spec.js'));
for (const f of found) {
  if (!EXPECTED_SPECS.includes(f)) {
    fail(`${f} is not in EXPECTED_SPECS — add it or remove it`);
  }
}

// ---------------------------------------------------------------------------
// 2. helpers.js API surface
// ---------------------------------------------------------------------------
section('helpers.js exports');

const EXPECTED_HELPER_EXPORTS = [
  'url',
  'handleAuthentikIfNeeded',
  'goAndAuth',
  'DOMAIN',
  'ADMIN_USER',
  'ADMIN_PASSWORD',
];

let helpers;
try {
  helpers = require(path.join(SMOKE_DIR, 'helpers.js'));
  for (const key of EXPECTED_HELPER_EXPORTS) {
    if (key in helpers) {
      pass(`exports '${key}'`);
    } else {
      fail(`missing export '${key}'`);
    }
  }
  if (typeof helpers.url === 'function') {
    pass("url('sub') returns a string");
    const result = helpers.url('auth');
    if (typeof result === 'string' && result.startsWith('https://')) {
      pass(`url('auth') => ${result}`);
    } else {
      fail(`url('auth') returned unexpected value: ${result}`);
    }
  }
} catch (err) {
  fail(`helpers.js failed to load: ${err.message}`);
}

// ---------------------------------------------------------------------------
// 3. global-setup.js API surface
// ---------------------------------------------------------------------------
section('global-setup.js exports');

let globalSetup;
try {
  globalSetup = require(path.join(SMOKE_DIR, 'global-setup.js'));
  if (typeof globalSetup === 'function') {
    pass('default export is a function (globalSetup)');
  } else {
    fail(`default export is not a function (got ${typeof globalSetup})`);
  }
  if (typeof globalSetup.performAuthentikLogin === 'function') {
    pass('exports performAuthentikLogin');
  } else {
    fail('missing named export performAuthentikLogin');
  }
} catch (err) {
  fail(`global-setup.js failed to load: ${err.message}`);
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------
console.log('');
if (failures === 0) {
  console.log(`All static smoke checks passed.`);
  process.exit(0);
} else {
  console.error(`${failures} check(s) failed.`);
  process.exit(1);
}
