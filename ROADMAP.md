# Roadmap

Future improvements for professionalism, maintainability, and modularity.

## Modular Compose Layout

Split the single large `docker-compose.yml` into domain-focused files such as:

- `compose.core.yml`
- `compose.media.yml`
- `compose.monitoring.yml`
- `compose.vpn.yml`

This would make service ownership clearer and allow partial stack installs or updates.

## Shared Compose Patterns

Introduce YAML anchors or generated snippets for repeated patterns:

- Traefik router labels
- TLS/certresolver labels
- common restart/security defaults
- PUID/PGID/TZ environment blocks
- common volume conventions

This would reduce duplication and make service additions less error-prone.

## Installer Module Split

Break `install.sh` into focused shell modules:

- `lib/log.sh`
- `lib/env.sh`
- `lib/storage.sh`
- `lib/templates.sh`
- `lib/docker.sh`
- `lib/services.sh`

The current installer is readable, but it owns prompting, secrets, templating, storage mounts, stack startup, generated scripts, and summary output in one file.

## Service Metadata Source

Create a structured service registry, for example `services.yml`, that describes each service once:

- service name
- category
- subdomain
- auth method
- internal port
- data directories
- OIDC client needs
- post-install script

The README tables, summary output, directory creation, OIDC client generation, and some Traefik labels could then be generated from the same source of truth.

Initial implementation lives in `services.yml`. It records service category, subdomain, auth method, internal port, data directories, OIDC client environment variables, and post-install script ownership. `scripts/doctor.sh` validates that the registry exists and references real post-install scripts.

## Validation And Doctor Command

Add and maintain a `scripts/doctor.sh` / `./install.sh --check` mode that validates:

- required commands
- Docker daemon availability
- Compose syntax
- DNS records
- required ports
- generated templates
- mount health
- required `.env` variables
- expected service health after startup

This would make failures easier to diagnose before a full install attempt.

The first implementation should stay dependency-light and run on a fresh checkout. Deeper checks can become optional flags so users can run fast local validation before install and fuller network/runtime validation on the target VPS.

Initial implementation is tracked as `scripts/doctor.sh`, exposed via `./install.sh --check`, and run by CI.

## Idempotent Service Configuration

Make every post-install configuration script safe to re-run after partial failure:

- inspect current service state before writing
- create missing config
- update existing config in place
- verify the final state
- avoid parsing transient logs as the only source of credentials
- pass secrets through environment variables instead of interpolating them into shell commands

This reduces manual recovery work when first boot races, slow migrations, or service-specific setup steps fail.

Implemented for all post-install scripts. Scripts wait for service readiness, update existing state where supported, and verify final state. The installer now fails the install if post-install configuration cannot prove completion.

The full media pipeline is now wired end-to-end from startup: `configure-sonarr.sh`, `configure-radarr.sh`, and `configure-lidarr.sh` add qBittorrent as download client and set the root media folder; `configure-prowlarr.sh` registers the arr apps as sync targets and seeds the YTS movie indexer; `configure-jellyseerr.sh` connects Radarr and Sonarr with the correct quality profiles and root folders in addition to the Jellyfin connection.

## OIDC-First Authentication

Prefer Authentik/OIDC over local app accounts wherever the upstream service supports it:

- enable and configure the Jellyfin OIDC plugin by default
- reduce first-run local admin prompts where automation is possible
- automate Jellyfin first-run setup with an API-first script using `.env` admin credentials
- create default Jellyfin libraries from configurable media paths, skipping missing directories
- automate Jellyseerr setup after Jellyfin is initialized, including Jellyfin connection/API key setup
- document which services still require a local break-glass/admin account
- keep generated OIDC clients, scopes, callback URLs, and group mappings in one repeatable setup path
- verify browser login flows after install so users do not have to discover OIDC failures manually

The goal is fewer independent passwords, fewer repeated logins, and a consistent Authentik-backed user experience across the stack.

Implementation should prefer service APIs first, stable config edits second, and Playwright/browser automation only for apps that do not expose a reliable setup API.

Current automation configures native OIDC for Homarr, Nextcloud, Audiobookshelf, Grafana, and Vaultwarden, plus an Authentik OIDC client for Jellyfin's optional SSO plugin. The README documents remaining local break-glass accounts explicitly; Jellyfin plugin installation remains optional because it still requires a plugin install step inside Jellyfin.

Known OIDC gaps discovered during live browser testing — all resolved:

- **Audiobookshelf** (ISSUE-013): Fixed. Authentik blueprint now registers both the subfolder (`/audiobookshelf/auth/openid/callback`) and root callback paths. `configure-audiobookshelf-oidc.sh` clears the subfolder override and verifies all endpoints.
- **Nextcloud** (ISSUE-011): Fixed. `install.sh` now runs `chown -R 33:33 data/nextcloud` before first boot so `config.php` is always readable by the container's `www-data` process.
- **Headscale** (ISSUE-015): Fixed. The Traefik `authentik-outpost` router rule was updated to Traefik v3 Go regex syntax, which correctly routes all subdomain outpost callbacks to `authentik-server:9000`.
- **Booklore** (ISSUE-014): Fixed. `scripts/configure-booklore.sh` creates the initial admin account via the Booklore setup API and is wired into `install.sh`.

## Version And Update Policy

Document and automate a safer update process:

- pinned image versions by default
- optional update script
- backup reminder before upgrades
- changelog notes for service version bumps
- rollback guidance for failed upgrades

Initial implementation is in `scripts/update.sh`, which requires a recent backup by default, can run `scripts/backup.sh` first, records replaced image state, pulls configured image tags, and redeploys through `scripts/start.sh`.

## Tracked Start Script

Keep `scripts/start.sh` as a versioned script rather than generating it during install.

This would make startup behavior reviewable, testable, and easier to maintain.

Implemented as a tracked executable `scripts/start.sh`; the installer now only verifies that the script is available.

## Backup Restore And Update Scripts

Add versioned operational scripts for routine maintenance:

- `scripts/backup.sh`
- `scripts/restore.sh`
- `scripts/update.sh`

Updates should require or strongly prompt for a recent backup, record the image versions being replaced, and document rollback steps for database-backed services.

Implemented as `scripts/backup.sh`, `scripts/restore.sh`, and `scripts/update.sh`.

## CI And Static Checks

Add basic repository checks:

- `docker compose config`
- `shellcheck` for shell scripts
- YAML linting
- template placeholder validation
- executable bit checks for scripts

These checks would catch many regressions before users discover them during installation.

Initial CI coverage lives in `.github/workflows/checks.yml` and runs shell syntax, ShellCheck, and the doctor command.

A Playwright browser smoke test suite now lives in `tests/smoke/` and covers all 15 services. It runs against the live stack and verifies that each service is reachable, auth passes end-to-end, and a key feature is accessible. Two improvements remain:

- **Post-install verification**: the installer should optionally run `npx playwright test` against the freshly deployed stack so OIDC misconfigurations and unreachable services are caught before the user is handed a summary screen.
- **CI smoke gate**: the smoke suite cannot easily run in a standard CI runner (no live stack), but a subset of static checks — verifying that each test file exists, that selectors compile, and that helper utilities export the expected API — could run in CI to catch regressions before deployment.
