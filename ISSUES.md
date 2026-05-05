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

**Fix:** Pinned all images to explicit versions. Homarr uses `v1.59.3` and Booklore uses `v2.2.2` because those are the valid GHCR tags verified during live update testing.

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

## ISSUE-011 - Nextcloud configuration error on startup

**Status:** Fixed
**Severity:** High
**Area:** Nextcloud

Navigating to `cloud.zenlabs.us` showed: _"Configuration was not initialized correctly, not overwriting /var/www/html/config/config.php"_. Nextcloud's `config.php` was not readable during runtime.

**Root cause:** `data/nextcloud/config/`, `data/nextcloud/custom_apps/`, and `data/nextcloud/data/` were owned by `developer:developer` (the install user) instead of `www-data:www-data` (UID/GID 33). The container process could not read `config.php` (mode 640, wrong owner). `config.php` was actually fully written during the initial install — the error was purely a permissions problem.

**Fix:** Added `chown -R 33:33 data/nextcloud 2>/dev/null || true` to `setup_directories()` in `install.sh`, following the same pattern already used for Grafana. This runs on every `install.sh` invocation — before first boot and on any re-run — so ownership is always correct before the container starts. The Nextcloud entrypoint only runs its own `chown -R www-data /var/www/html` on the first boot (before `version.php` exists); on every subsequent container restart it skips that path, leaving any pre-existing installer-owned subdirs broken. A pending minor-version DB upgrade (33.0.2 → 33.0.3) was also applied via `occ upgrade` on the live instance.

## ISSUE-012 - Homarr dashboard has no default service bookmarks

**Status:** Open
**Severity:** Low
**Area:** Homarr / Post-install configuration

After OIDC login, the Homarr dashboard is empty. The `configure-homarr.sh` script sets up OIDC but does not seed any default tiles or bookmarks for the stack's services.

**Impact:** New installs require the user to manually add all service links to the Homarr dashboard before it is useful as a home page.

**Suggested fix:** Add a default board configuration (JSON import or Homarr API call) to `configure-homarr.sh` that seeds bookmarks for all services defined in `services.yml`. Homarr supports importing board configurations via its settings UI or API.

## ISSUE-013 - Audiobookshelf OIDC callback URL is wrong

**Status:** Fixed
**Severity:** High
**Area:** Audiobookshelf / Authentik OIDC

Clicking "Login with OpenId" in Audiobookshelf redirects to Authentik, which issues an auth code, then redirects to `https://audiobooks.zenlabs.us/auth/openid/callback`. Audiobookshelf rejects the callback with `Unauthorized` and bounces back to the login page.

**Root cause:** The redirect URI registered in the Authentik application omits the `/audiobookshelf` base path. The service is mounted at `/audiobookshelf`, so the correct callback URL is `https://audiobooks.zenlabs.us/audiobookshelf/auth/openid/callback`.

**Impact:** OIDC single sign-on for Audiobookshelf is non-functional. Users must log in with a local Audiobookshelf account.

**Fix:** The Authentik blueprint template now registers four redirect URIs for Audiobookshelf: both the `/audiobookshelf/auth/openid/callback` and `/auth/openid/callback` variants (plus the corresponding mobile-redirect paths), covering the subfolder and root cases. `configure-audiobookshelf-oidc.sh` explicitly sets `authOpenIDSubfolderForRedirectURLs` to the empty string and verifies all OIDC endpoint URLs after patching. ABS is restarted after configuration to reload the OIDC strategy.

## ISSUE-014 - Booklore initial admin account not created

**Status:** Fixed
**Severity:** High
**Area:** Booklore / Post-install configuration

Navigating to `books.zenlabs.us` shows the first-run setup wizard at `/setup` — Booklore's initial admin account was never created during installation.

**Impact:** Booklore is completely inaccessible. The book library and reading management features are unavailable.

**Fix:** Added `scripts/configure-booklore.sh`. It waits for the healthcheck endpoint, skips if `GET /api/v1/setup/status` reports setup already complete, then POSTs to `POST /api/v1/setup` with the stack's `ADMIN_USER`/`ADMIN_EMAIL`/`ADMIN_PASSWORD` credentials. Credentials are JSON-escaped before construction and piped via stdin to curl inside the container. Setup completion is verified before the script exits. Wired into `install.sh` alongside the other first-run scripts and added `post_install_script` to the Booklore entry in `services.yml`.

## ISSUE-015 - Headscale Authentik outpost callback is stuck

**Status:** Open
**Severity:** High
**Area:** Headscale / Authentik forward_auth

The Authentik outpost for `headscale.zenlabs.us` processes the OIDC authorization code at `/outpost.goauthentik.io/callback` but never issues the final redirect back to `/web`. The browser is stuck at the callback URL indefinitely with an empty response body.

**Impact:** The Headscale admin UI at `headscale.zenlabs.us/web` is inaccessible via browser. The Headscale gRPC/HTTP API may still be reachable, but the web UI requires completing the OIDC flow.

**Suggested fix:** Check the Authentik outpost logs (`docker compose logs authentik-proxy`) for errors during callback processing. Verify the outpost's `client_id` and `client_secret` match the Authentik application config. Ensure the outpost container can reach `auth.zenlabs.us` over the internal Docker network.
