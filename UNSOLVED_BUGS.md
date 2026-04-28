# Unsolved Bugs

_(No open bugs.)_

---

## BUG-001 — Booklore image inaccessible on GHCR

**Status:** Resolved (2026-04-28)  
**Service:** Booklore (`books.<domain>`)

### Root cause

The upstream project moved GitHub organizations. All images under `ghcr.io/adityachandelgit/` became private. The project is now maintained at `github.com/the-booklore/booklore` and publishes to `ghcr.io/the-booklore/booklore:latest`.

The new image also requires a MariaDB sidecar (the old image was self-contained).

### Fix applied

- Updated image to `ghcr.io/the-booklore/booklore:latest`
- Added `booklore-db` MariaDB 11.4.8 sidecar service
- Updated environment variables (`USER_ID`/`GROUP_ID` instead of `PUID`/`PGID`, added DB credentials)
- Updated volumes (`/app/data` instead of `/data`, added `/bookdrop`)
- Added `BOOKLORE_DB_PASSWORD` and `BOOKLORE_DB_ROOT_PASSWORD` to `install.sh` secrets and `.env`
- Added `data/booklore-db` and `data/booklore-bookdrop` to directory creation list
- Removed `profiles: [booklore]` — service now starts with the rest of the stack
