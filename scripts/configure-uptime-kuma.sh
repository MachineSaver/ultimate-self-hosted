#!/usr/bin/env bash
# Creates the Uptime Kuma admin account via its Socket.IO setup event.
# Called automatically by install.sh; safe to re-run (skips if already initialized).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

[[ -f .env ]] || { echo "ERROR: .env not found. Run install.sh first."; exit 1; }
# shellcheck source=/dev/null
set -a; source .env; set +a

echo "Waiting for Uptime Kuma to be ready..."
retries=0
until docker compose exec -T uptime-kuma node -e \
  "fetch('http://localhost:3001').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
  2>/dev/null; do
  retries=$((retries+1))
  [[ $retries -gt 24 ]] && { echo "ERROR: Uptime Kuma did not become ready in 2 minutes."; exit 1; }
  sleep 5
done

docker compose exec -T \
  -e UK_USER="${ADMIN_USER}" \
  -e UK_PASS="${ADMIN_PASSWORD}" \
  uptime-kuma node - << 'JSEOF'
const { io } = require('socket.io-client');
const { UK_USER, UK_PASS } = process.env;

const socket = io('http://localhost:3001', {
  transports: ['websocket'],
  reconnection: false
});

const timeout = setTimeout(() => {
  process.stderr.write('ERROR: Timed out waiting for Uptime Kuma socket.\n');
  socket.disconnect();
  process.exit(1);
}, 15000);

socket.on('connect', () => {
  socket.emit('setup', { username: UK_USER, password: UK_PASS }, (res) => {
    clearTimeout(timeout);
    socket.disconnect();
    if (res?.ok) {
      process.stdout.write(`Done! Uptime Kuma admin account created (${UK_USER}).\n`);
      process.exit(0);
    }
    const msg = res?.msg || 'unknown error';
    if (msg.toLowerCase().includes('already') || msg.toLowerCase().includes('initialized')) {
      process.stdout.write('Uptime Kuma already initialized — skipping.\n');
      process.exit(0);
    }
    process.stderr.write(`ERROR: Setup failed — ${msg}\n`);
    process.exit(1);
  });
});

socket.on('connect_error', (err) => {
  clearTimeout(timeout);
  process.stderr.write(`ERROR: Connection error — ${err.message}\n`);
  process.exit(1);
});
JSEOF
