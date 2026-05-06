# Roadmap

Future improvements for professionalism, maintainability, and modularity.

## Modular Compose Layout

Split the single large `docker-compose.yml` into domain-focused files such as:

- `compose.core.yml`
- `compose.media.yml`
- `compose.monitoring.yml`
- `compose.vpn.yml`

This would make service ownership clearer and allow partial stack installs or updates.

Implemented as five files: `compose.core.yml` (Traefik, Postgres, Redis, Authentik, Homarr), `compose.cloud.yml` (Nextcloud, Vaultwarden), `compose.media.yml` (Jellyfin, Jellyseerr, Audiobookshelf, Navidrome, arr stack, qBittorrent, Booklore), `compose.monitoring.yml` (Prometheus, Grafana, Uptime Kuma, exporters), and `compose.vpn.yml` (Headscale, wg-easy). All scripts define a `COMPOSE_FILES` array and pass all five files to every `docker compose` invocation so cross-file `depends_on` and shared networks continue to work. The monolithic `docker-compose.yml` has been removed.

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

The full media pipeline is now wired end-to-end from startup: `configure-sonarr.sh`, `configure-radarr.sh`, and `configure-lidarr.sh` add qBittorrent as download client and set the root media folder; `configure-prowlarr.sh` creates or repairs the arr app sync targets, enables Prowlarr add-only sync, and seeds the YTS movie indexer; `configure-jellyseerr.sh` connects Radarr and Sonarr with the correct quality profiles and root folders in addition to the Jellyfin connection.

## OIDC-First Authentication

Prefer Authentik/OIDC over local app accounts wherever the upstream service supports it:

- enable and configure the Jellyfin OIDC plugin by default
- reduce first-run local admin prompts where automation is possible
- automate Jellyfin first-run setup with an API-first script using `.env` admin credentials
- create default Jellyfin libraries from configurable media paths, skipping missing directories
- configure default Jellyfin libraries to refresh at least once per day
- automate Jellyseerr setup after Jellyfin is initialized, including Jellyfin connection/API key setup
- document which services still require a local break-glass/admin account
- keep generated OIDC clients, scopes, callback URLs, and group mappings in one repeatable setup path
- verify browser login flows after install so users do not have to discover OIDC failures manually

The goal is fewer independent passwords, fewer repeated logins, and a consistent Authentik-backed user experience across the stack.

Implementation should prefer service APIs first, stable config edits second, and Playwright/browser automation only for apps that do not expose a reliable setup API.

Current automation configures native OIDC for Homarr, Jellyfin, Nextcloud, Audiobookshelf, Grafana, and Vaultwarden. The README documents remaining local break-glass accounts explicitly, including Jellyfin's local admin account for recovery and Jellyseerr integration.

## Homarr Default Dashboard Experience

Improve the first-login Homarr board from a static service launcher into a useful default operations dashboard. Keep the current grouped service bookmarks, but add visual polish and live widgets that match the services installed by this stack.

Recommended implementation order:

- [x] Add a cleaned-up local glassmorphism theme inspired by `https://pastebin.com/aMG7t7He`; avoid broad fragile selectors where possible.
- [x] Add the native Homarr Docker stats widget, using the existing read-only Docker socket mount.
- [x] Add a server/system resources widget using a supported backend such as Glances or Dash.; use `https://github.com/lxBlazarxl/System-Monitor-iFrame-Widget-for-Homarr` as inspiration only unless native widgets are insufficient.
- [x] Add the qBittorrent Download Client widget.
- [x] Add the Sonarr/Radarr/Lidarr media calendar widget.
- [x] Add the Jellyfin Media Server Streams widget.
- [ ] Add Jellyseerr request list and request stats widgets if the Homarr integration can be seeded reliably.
- [ ] Add lightweight utility widgets such as RSS feed, Weather, and Date/time where they do not create first-run configuration friction.

Implementation notes:

- Seed required Homarr integrations/API credentials idempotently during `scripts/configure-homarr.sh` or a dedicated follow-up script.
- Prefer native Homarr widgets over custom iframe services when Homarr supports the same data directly.
- Keep the board useful even when an integration cannot be configured yet; failed optional widgets should not block the whole install.
- Do not include the Media Releases widget by default.

Live verification notes:

- 2026-05-05: `scripts/configure-homarr.sh` now applies a board-local glassmorphism theme to the Home board through Homarr's `board.custom_css` field, independent of whether the service bookmarks were already seeded.
- 2026-05-05: Live `home.zenlabs.us` update applied by copying the updated script to `/home/developer/ultimate-self-hosted/scripts/configure-homarr.sh` and re-running it. The script detected the existing Home board, skipped reseeding, applied the theme, and restarted Homarr.
- 2026-05-05: Live DB verification inside the Homarr container showed `primary_color=#38bdf8`, `secondary_color=#fb923c`, `opacity=82`, `item_radius=md`, and a non-empty `custom_css` value containing the `--ush-surface` theme marker. `curl -k https://home.zenlabs.us/` returned `HTTP 200`.
- 2026-05-06: Repository automation now adds a private Glances service for Homarr's native System Resources widget, connects Homarr to the internal network, and idempotently seeds an Operations section with Docker stats and System Resources widgets on both fresh and existing Home boards.
- 2026-05-06: Repository automation now idempotently seeds Homarr's native Download Client widget in the Operations section, creates the private `qBittorrent` integration at `http://qbittorrent:8080`, and stores the configured admin WebUI credentials as Homarr-encrypted integration secrets.
- 2026-05-06: Repository automation now also seeds Homarr's native Calendar widget for Sonarr, Radarr, and Lidarr by reading each arr API key from its container config and storing it as an encrypted Homarr integration secret when available.
- 2026-05-06: Repository automation now seeds the native Jellyfin Media Server Streams widget (`mediaServer` kind) in the Operations section. `configure-homarr.sh` fetches the `ultimate-self-hosted-jellyfin-oidc` API key from the running Jellyfin container, creates a `jellyfin` integration at `http://jellyfin:8096`, and seeds the widget at row 12 of the Operations section (section height expanded from 12 to 16 rows). `showOnlyPlaying` is set to `false` so paused sessions remain visible. Verified live: Jellyfin integration and `mediaServer` item confirmed in Homarr DB.

### Jellyfin OIDC Migration

**Status:** Completed and live verified
**Priority:** High
**Owner:** Repository automation plus live instance verification

Move Jellyfin from Traefik forward-auth to Jellyfin-native OIDC through the SSO Authentication plugin. The current forward-auth router protects `jellyfin.<domain>` before Jellyfin can answer its own API, websocket, server picker, and media playback requests. That blocks normal Jellyfin client behavior even though the public page can redirect through Authentik.

Planned implementation:

- [x] Remove `authentik@file` from the Jellyfin Traefik router only; keep Authentik forward-auth for services that do not support native OIDC.
- [x] Keep `JELLYFIN_PublishedServerUrl=https://jellyfin.${DOMAIN}` so clients advertise the public HTTPS endpoint.
- [x] Keep the generated Authentik OIDC provider/application for Jellyfin with callback `https://jellyfin.${DOMAIN}/sso/OID/redirect/authentik`.
- [x] Add an idempotent `scripts/configure-jellyfin-oidc.sh` that runs after `scripts/configure-jellyfin.sh`.
- [x] Automate SSO plugin configuration through Jellyfin's SSO API at `/sso/OID/Add/authentik?api_key=...` once the plugin is installed and loaded.
- [x] Prefer a permissive single-user default first: enable the provider, allow all folders, avoid required group/role claims, and keep the local Jellyfin admin account as break-glass access.
- [x] Add or document a login entry point for `https://jellyfin.${DOMAIN}/sso/OID/start/authentik`.
- [x] Update README service/auth tables so Jellyfin is described as native OIDC with a local break-glass account, not forward-auth.
- [x] Update smoke tests so Jellyfin verification expects the public API to answer Jellyfin JSON and then verifies the Authentik SSO login path on the live stack.
- [x] Verify the migration against the live `jellyfin.zenlabs.us` instance.

Open implementation questions:

- [x] Confirm the unattended plugin install path on the live pinned Jellyfin image. Current automation uses Jellyfin's plugin repository/package APIs and restarts Jellyfin when the SSO plugin is first installed.
- [x] Decide whether the automation should create a Jellyfin API key explicitly or reuse the first-run admin token only during configuration. The OIDC script now creates/reuses a dedicated `ultimate-self-hosted-jellyfin-oidc` API key for the plugin API.
- [x] Confirm whether the login page button can be written through Jellyfin API/configuration or whether the documented SSO start URL is sufficient for the first pass. First pass uses the plugin start URL directly in docs and smoke tests.

Completion criteria:

- `https://jellyfin.zenlabs.us/System/Info/Public` returns Jellyfin public server JSON without a 302 to Authentik.
- `https://jellyfin.zenlabs.us/sso/OID/start/authentik` starts Authentik login and returns to Jellyfin successfully.
- Selecting the populated "Zenlabs Jellyfin" server in the Jellyfin web UI loads the library instead of returning to the server picker.
- At least one movie can be opened and playback starts through `jellyfin.zenlabs.us`.
- Local Jellyfin admin login still works for recovery.
- Live verification notes are added to this roadmap entry, including the exact date and any remaining client limitations.

Live verification notes:

- 2026-05-05: Live migration applied via `developer@zenlabs.us`. The live `docker-compose.yml` Jellyfin router no longer has `traefik.http.routers.jellyfin.middlewares=authentik@file`; Jellyfin was recreated and Traefik was restarted to force Docker-provider router refresh.
- 2026-05-05: `scripts/configure-jellyfin-oidc.sh` installed Jellyfin SSO Authentication `3.5.2.4`, restarted Jellyfin, and configured provider `authentik`.
- 2026-05-05: Existing Authentik Jellyfin OAuth2 provider was updated in place to client ID `JELLYFIN_OIDC_CLIENT_ID`, callback `https://jellyfin.zenlabs.us/sso/OID/redirect/authentik`, and application slug `jellyfin`.
- 2026-05-05: `curl -k -i https://jellyfin.zenlabs.us/System/Info/Public` returns `HTTP/2 200` with Jellyfin JSON and `StartupWizardCompleted:true`, with no Authentik 302.
- 2026-05-05: `GET https://jellyfin.zenlabs.us/sso/OID/start/authentik` returns `HTTP/2 302` to `auth.zenlabs.us/application/o/authorize` with client ID `jellyfin-1393d53e0a761711` and callback `https://jellyfin.zenlabs.us/sso/OID/redirect/authentik`.
- 2026-05-05: Browser verification from the live host completed Authentik login, returned to Jellyfin, opened the Jellyfin WebSocket, and landed on `https://jellyfin.zenlabs.us/web/index.html#/home.html` with visible Home, Audiobooks, Books, Movies, Music, and TV Shows navigation.
- 2026-05-05: Follow-up storage check found the Storage Box mounted correctly with 86 GB used, but media was stored in top-level folders (`/mnt/storagebox/movies`, `/mnt/storagebox/tv`, `/mnt/storagebox/music`, `/mnt/storagebox/audiobooks`) while the stack was mounting `/mnt/storagebox/media`. Live `.env` and `scripts/start.sh` were updated to use `MEDIA_DIR=/mnt/storagebox`, and the repository installer/start script now uses the Storage Box mount root as `MEDIA_DIR`.
- 2026-05-05: Jellyfin now sees the media files inside the container under `/media/movies`, `/media/tv`, `/media/music`, and `/media/audiobooks`.
- 2026-05-05: Local Jellyfin break-glass account `akadmin` had lost administrator permission (`IsAdmin false`), blocking library refresh. The Jellyfin DB was backed up to `/tmp/jellyfin.db.before-admin.<timestamp>`, permission kind `0` was restored to `Value=1`, and `akadmin` verified as `IsAdmin true`.
- 2026-05-05: Library refresh completed and Jellyfin reported `Movie=21 Episode=35 Audio=38`.
- 2026-05-05: Playback path verified through the public endpoint: first indexed movie `Frozen` returned playback info with one media source, and a ranged stream request to `https://jellyfin.zenlabs.us/Videos/.../stream` returned `HTTP 206` with `content-type=video/mp4`.

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

- **Post-install verification**: implemented. After `configure_services`, the installer prompts to run `npx playwright test` (or auto-runs with `./install.sh --smoke`). Generates `tests/.env.test` from install credentials, installs dependencies if missing, runs the full smoke suite, and warns on failure without blocking the summary screen.
- **CI smoke gate**: implemented in `tests/scripts/check-smoke-static.js` and wired into a `smoke-static` CI job. Checks that every expected spec file exists, that `helpers.js` and `global-setup.js` export the correct API, and runs `npx playwright test --list` to enumerate all tests — all without a live stack or browser.
