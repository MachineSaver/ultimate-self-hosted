# Unsolved Bugs

---

## BUG-001 — Booklore image inaccessible on GHCR

**Status:** Open  
**Service:** Booklore (`books.<domain>`)  
**Workaround:** Service excluded from default stack via `profiles: [booklore]` in `docker-compose.yml`

### What broke

`ghcr.io/adityachandelgit/booklore-app:latest` returns `denied` from the registry when `docker compose pull` runs. All image variants tried returned the same error:

- `ghcr.io/adityachandelgit/booklore-app:latest` → `denied`
- `ghcr.io/adityachandelgit/booklore:latest` → `denied`
- `ghcr.io/adityachandelgit/booklore-api:latest` → `denied`
- `ghcr.io/adityachandelgit/booklore-fe:latest` → `denied`
- `adityachandel21/booklore:latest` (Docker Hub) → `not found`

The `denied` response (vs `not found`) indicates the packages exist on GHCR but have been made private — likely a visibility change in the upstream project.

### What was tried

Manually pulling each image variant above on the target server (`168.119.156.225`, Docker 29.4.1). All failed. No public Docker Hub mirror was found.

### Next likely steps

1. Check the upstream repo at `https://github.com/adityachandelgit/BookLore` for:
   - Release notes / changelog mentioning an image rename or registry move
   - The current `docker-compose.yml` in the repo to find the live image reference
   - Whether a GitHub Packages authentication step is now required
2. If the project moved to a paid/private model, evaluate a replacement (e.g. Calibre-Web, Kavita)
3. Once the correct public image is found, update `docker-compose.yml` and remove the `profiles: [booklore]` workaround

### Impact

Booklore is excluded from the stack. All other services are unaffected. The `books.<domain>` subdomain will return a 404 until this is resolved and the profile is removed.
