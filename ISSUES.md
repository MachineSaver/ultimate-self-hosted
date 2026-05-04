# Issues

Current bug and risk tracker for the stack.

## ISSUE-001 - Authentik timeout can skip starting the remaining stack

**Status:** Fixed
**Severity:** High
**Area:** Installer orchestration

`install.sh` waits for Authentik during `start_stack()`. If Authentik takes longer than the retry window, the function prints warnings and returns success before running the step that starts the remaining services.

**Impact:** Later configuration scripts may run against services that were never started, producing confusing partial installs.

**Suggested fix:** Treat the timeout as a hard failure, or continue with `docker compose up -d` before returning. The installer should make the final stack state explicit.

## ISSUE-002 - Raw `.env` writing and template substitution are unsafe for special characters

**Status:** Fixed
**Severity:** High
**Area:** Configuration generation

Installer prompts are written directly into `.env` and substituted into templates with `sed`.

**Impact:** Values containing spaces, `$`, `&`, `|`, backslashes, quotes, or newlines can break shell sourcing, YAML, SQL, or generated service config.

**Suggested fix:** Add input validation and escaping. Prefer a structured template renderer or a constrained allowed-character policy for values that must become shell/YAML/SQL.

## ISSUE-003 - `python3` is optional but required by setup paths

**Status:** Fixed
**Severity:** Medium
**Area:** Requirements

`install.sh` treats `python3` as optional, but the Authentik rename flow and Headscale setup use Python JSON parsing.

**Impact:** Installs can fail later despite passing the requirements check.

**Fix:** Replaced all three `python3` JSON-parsing calls with portable shell pipelines. The Authentik pk lookup uses `grep -o '"pk":[0-9]*'`; the Headscale flow resolves the numeric user ID from `users list -o json` with `awk`, and extracts the key with `grep`/`cut`. The dead `python3 || true` line in `check_requirements` was removed.

## ISSUE-004 - Unpinned `latest` images reduce reproducibility

**Status:** Fixed
**Severity:** Medium
**Area:** Docker images

Several services use `:latest` tags.

**Impact:** Fresh installs can change behavior without a repository change, and upstream breaking changes can appear during normal updates.

**Fix:** Pinned all 19 images to explicit versions as of 2026-04-30: homarr 1.59.3, jellyfin 10.11.8, jellyseerr 3.2.0, audiobookshelf 2.34.0, booklore 2.3.0, navidrome 0.61.2, sonarr 4.0.17.2952-ls309, radarr 6.1.1.10360-ls300, lidarr 3.1.0.4875-ls26, prowlarr 2.3.5.5327-ls144, qbittorrent 5.1.4-r3-ls452, headscale 0.28.0, headscale-ui 2026.03.17, uptime-kuma 2.2.1, prometheus v3.11.3, node-exporter v1.11.1, cadvisor v0.56.2, grafana 13.0.1, vaultwarden 1.35.8.

## ISSUE-005 - Some Traefik middlewares are defined but not applied

**Status:** Fixed  
**Severity:** Medium  
**Area:** Reverse proxy configuration

`secure-headers`, `rate-limit`, and `compress` are defined in Traefik dynamic config, but they do not appear to be applied globally or to routers. The qBittorrent header middleware is declared but not attached to the qBittorrent router.

**Impact:** Expected security/performance behavior may not actually be active.

**Suggested fix:** Decide which middlewares should be global versus service-specific, then wire them into entrypoints or router middleware chains.

## ISSUE-006 - Missing preflight/doctor checks make install failures reactive

**Status:** Fixed
**Severity:** High
**Area:** Validation and operations

The installer checks for Docker, Compose, curl, openssl, and Docker daemon availability, but it does not provide a standalone diagnostic path for validating repository state, generated config, DNS, template output, or mount health.

**Impact:** Users can discover DNS, Compose, template, port, or Storage Box problems only after a full install attempt has already made changes.

**Fix:** Added `scripts/doctor.sh` and wired `./install.sh --check` to it. Static checks validate required commands, shell syntax, executable bits, template presence, unreplaced placeholders, floating image tags, environment coverage, Compose rendering, and local port state. Optional `--network` and `--runtime` flags add DNS, Docker runtime, and Storage Box mount checks.

## ISSUE-007 - Service configuration scripts are not consistently idempotent

**Status:** Fixed
**Severity:** High
**Area:** Post-install automation

Post-install scripts can configure services, but some scripts rely on first-run state or append/create behavior instead of detecting and updating current state. qBittorrent depends on a temporary password parsed from logs, and Nextcloud OIDC configuration does not first inspect existing providers.

**Impact:** Re-running failed or partially completed installs can skip needed repair work, duplicate configuration, or report success without proving the desired final state.

**Fix:** Post-install scripts now follow a wait, inspect/update, and verify pattern. Nextcloud creates or updates the named `authentik` OIDC provider and verifies it exists. Audiobookshelf verifies OpenID auth settings after updating them. Headscale waits for readiness and verifies the admin user exists before creating a pre-auth key. qBittorrent first tests desired credentials, falls back to the temporary password only when needed, and fails loudly if neither path can prove the desired final state. Jellyseerr now verifies and refreshes the Jellyfin connection even when it was already initialized. Uptime Kuma and Homarr verify their database changes after writing. The installer now stops if post-install configuration fails instead of printing a clean setup-complete summary.

## ISSUE-008 - Shell and JSON quoting in service scripts can break with valid secrets

**Status:** Fixed
**Severity:** High
**Area:** Secret handling

Some service scripts interpolate user-provided credentials directly into shell command strings or JSON payloads. For example, qBittorrent credential setup builds a remote `bash -c` command containing the admin password.

**Impact:** Passwords containing quotes, backslashes, dollar signs, or other shell/JSON-sensitive characters can break configuration or send malformed API requests.

**Fix:** Service configuration scripts pass secrets through environment variables or quoted command arguments, construct JSON inside the target runtime where practical, and verify final state after updates. qBittorrent credential setup passes credentials through environment variables, URL-encodes form fields, and JSON-escapes preferences inside the container before calling the API.

## ISSUE-009 - Startup behavior is generated instead of versioned

**Status:** Fixed
**Severity:** Medium
**Area:** Operations

`install.sh` used to generate `scripts/start.sh` during installation.

**Impact:** Startup behavior is harder to review, lint, test, and evolve because the real operational script is embedded inside the installer.

**Fix:** Added `scripts/start.sh` as a tracked executable script. The installer now verifies that it exists instead of writing operational behavior during install.

## ISSUE-010 - No backup, restore, or deliberate update workflow

**Status:** Fixed
**Severity:** Medium
**Area:** Operations

The stack documents a direct `docker compose pull && docker compose up -d` update path, but it includes databases and application state that should be backed up before upgrades.

**Impact:** Routine updates can become risky, and failed upgrades have no documented rollback path.

**Fix:** Added `scripts/backup.sh`, `scripts/restore.sh`, and `scripts/update.sh`. Backups capture project config, `services.yml`, app data, Compose image state, and database dumps when PostgreSQL and Booklore MariaDB are reachable. Updates require a recent backup by default, can create one first, and record replaced image state for rollback guidance. Restore requires explicit `--yes` before overwriting local state.
