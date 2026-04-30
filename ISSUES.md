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

**Status:** Open  
**Severity:** High  
**Area:** Configuration generation

Installer prompts are written directly into `.env` and substituted into templates with `sed`.

**Impact:** Values containing spaces, `$`, `&`, `|`, backslashes, quotes, or newlines can break shell sourcing, YAML, SQL, or generated service config.

**Suggested fix:** Add input validation and escaping. Prefer a structured template renderer or a constrained allowed-character policy for values that must become shell/YAML/SQL.

## ISSUE-003 - `python3` is optional but required by setup paths

**Status:** Open  
**Severity:** Medium  
**Area:** Requirements

`install.sh` treats `python3` as optional, but the Authentik rename flow and Headscale setup use Python JSON parsing.

**Impact:** Installs can fail later despite passing the requirements check.

**Suggested fix:** Make `python3` a required dependency, or replace those calls with tooling guaranteed to exist in the relevant containers.

## ISSUE-004 - Unpinned `latest` images reduce reproducibility

**Status:** Open  
**Severity:** Medium  
**Area:** Docker images

Several services use `:latest` tags.

**Impact:** Fresh installs can change behavior without a repository change, and upstream breaking changes can appear during normal updates.

**Suggested fix:** Pin image versions for default installs and document a deliberate update process.

## ISSUE-005 - Some Traefik middlewares are defined but not applied

**Status:** Open  
**Severity:** Medium  
**Area:** Reverse proxy configuration

`secure-headers`, `rate-limit`, and `compress` are defined in Traefik dynamic config, but they do not appear to be applied globally or to routers. The qBittorrent header middleware is declared but not attached to the qBittorrent router.

**Impact:** Expected security/performance behavior may not actually be active.

**Suggested fix:** Decide which middlewares should be global versus service-specific, then wire them into entrypoints or router middleware chains.
