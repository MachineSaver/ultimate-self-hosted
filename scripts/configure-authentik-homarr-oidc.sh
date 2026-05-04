#!/usr/bin/env bash
# Ensures Authentik has the Homarr OIDC provider/application that Homarr expects.
# Safe to re-run. This repairs cases where the Authentik blueprint did not create
# the OIDC records on a fresh install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

echo "Waiting for Authentik to be ready..."
retries=0
until docker exec authentik-server /lifecycle/ak healthcheck >/dev/null 2>&1; do
  retries=$((retries+1))
  [[ $retries -gt 60 ]] && { echo "ERROR: Authentik did not become ready in time."; exit 1; }
  sleep 3
done

echo "Ensuring Homarr OIDC provider and application exist in Authentik..."

read -r -d '' PYCODE <<'PY' || true
import os
import re
import sys
from pathlib import Path

from django.apps import apps
from authentik.providers.oauth2.models import RedirectURI

blueprint_path = Path(os.environ.get("HOMARR_BLUEPRINT_PATH", "/blueprints/custom/01-oidc-providers.yml"))
if not blueprint_path.exists():
    raise SystemExit(f"Blueprint file not found: {blueprint_path}")

text = blueprint_path.read_text()
homarr_block = re.search(
    r"# ── Homarr.*?(?=# ── [A-Za-z])",
    text,
    re.S,
)
if homarr_block is None:
    raise SystemExit(f"Could not locate Homarr block in {blueprint_path}")

block_text = homarr_block.group(0)

def first_match(pattern: str, block: str) -> str | None:
    match = re.search(pattern, block)
    return match.group(1) if match else None

client_id = first_match(r'client_id:\s*"([^"]+)"', block_text)
client_secret = first_match(r'client_secret:\s*"([^"]+)"', block_text)
redirect_url = first_match(r'- url:\s*"([^"]+)"', block_text)
launch_url = first_match(r'meta_launch_url:\s*"([^"]+)"', block_text)

if not all([client_id, client_secret, redirect_url, launch_url]):
    missing = [name for name, value in {
        "client_id": client_id,
        "client_secret": client_secret,
        "redirect_url": redirect_url,
        "launch_url": launch_url,
    }.items() if not value]
    raise SystemExit(f"Could not parse Homarr settings from {blueprint_path}: missing {', '.join(missing)}")

Group = apps.get_model("authentik_core", "Group")
Application = apps.get_model("authentik_core", "Application")
Flow = apps.get_model("authentik_flows", "Flow")
ScopeMapping = apps.get_model("authentik_providers_oauth2", "ScopeMapping")
OAuth2Provider = apps.get_model("authentik_providers_oauth2", "OAuth2Provider")
CertificateKeyPair = apps.get_model("authentik_crypto", "CertificateKeyPair")
User = apps.get_model("authentik_core", "User")

group, _ = Group.objects.get_or_create(name="homarr-admins")

openid = ScopeMapping.objects.get(name="authentik default OAuth Mapping: OpenID 'openid'")
email = ScopeMapping.objects.get(name="authentik default OAuth Mapping: OpenID 'email'")
profile = ScopeMapping.objects.get(name="authentik default OAuth Mapping: OpenID 'profile'")
groups_mapping, _ = ScopeMapping.objects.update_or_create(
    name="Homarr groups claim",
    defaults={
        "scope_name": "groups",
        "expression": "return {\"groups\": [group.name for group in request.user.groups.all()]}",
    },
)

authorization_flow = Flow.objects.get(slug="default-provider-authorization-implicit-consent")
invalidation_flow = Flow.objects.get(slug="default-provider-invalidation-flow")
signing_key = CertificateKeyPair.objects.get(name="authentik Self-signed Certificate")

provider = OAuth2Provider.objects.filter(name="homarr").first()
if provider is None:
    provider = OAuth2Provider(name="homarr")
provider.client_id = client_id
provider.client_secret = client_secret
provider.client_type = "confidential"
provider.sub_mode = "hashed_user_id"
provider.include_claims_in_id_token = True
provider.issuer_mode = "per_provider"
provider.authorization_flow = authorization_flow
provider.invalidation_flow = invalidation_flow
provider.signing_key = signing_key
provider.save()
provider.redirect_uris = [RedirectURI(url=redirect_url, matching_mode="strict")]
provider.save()
provider.property_mappings.set([openid, email, profile, groups_mapping])

application = Application.objects.filter(slug="homarr").first()
if application is None:
    application = Application(slug="homarr", name="Homarr")
application.name = "Homarr"
application.slug = "homarr"
application.provider = provider
application.meta_launch_url = launch_url
application.meta_description = "Home dashboard"
application.policy_engine_mode = "any"
application.save()

admin_user = (
    User.objects.filter(type="internal")
    .exclude(username="AnonymousUser")
    .exclude(username__startswith="ak-outpost-")
    .order_by("id")
    .first()
    or User.objects.filter(username="akadmin").first()
)
if admin_user:
    admin_user.groups.add(group)

print("Homarr OIDC provider/application configured.")
PY

docker exec -i \
  -e HOMARR_BLUEPRINT_PATH="/blueprints/custom/01-oidc-providers.yml" \
  authentik-server ak shell -c "$PYCODE"

echo "Done! Authentik Homarr OIDC is configured."
