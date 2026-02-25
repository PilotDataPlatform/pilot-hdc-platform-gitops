#!/usr/bin/env bash
# Syncs RSA_PUBLIC_KEY in values.yaml files from the Keycloak realm public key.
# Fetches the key via terraform output from the OVH infra repo.
#
# Usage:
#   ./scripts/sync-rsa-public-key.sh                          # uses default OVH infra path
#   OVH_INFRA=~/other/path ./scripts/sync-rsa-public-key.sh   # custom path
#   ./scripts/sync-rsa-public-key.sh <raw-public-key>          # skip terraform, pass key directly
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPS_DIR="$REPO_ROOT/clusters/dev/apps"
OVH_INFRA="${OVH_INFRA:-$REPO_ROOT/../pilot-hdc-ovh-infra}"
TF_DIR="$OVH_INFRA/terraform/keycloak"

RAW_KEY="${1:-}"
if [[ -z "$RAW_KEY" ]]; then
  if [[ ! -d "$TF_DIR" ]]; then
    echo "ERROR: Terraform dir not found: $TF_DIR" >&2
    echo "Set OVH_INFRA to the pilot-hdc-ovh-infra repo root." >&2
    exit 1
  fi
  echo "Fetching key from terraform output ($TF_DIR)..."
  RAW_KEY=$(terraform -chdir="$TF_DIR" output -raw realm_rsa_public_key)
fi

# Wrap in PEM headers and base64 encode (what HDC services expect)
PEM=$(printf '%s\n%s\n%s' "-----BEGIN PUBLIC KEY-----" "$RAW_KEY" "-----END PUBLIC KEY-----")
B64=$(echo -n "$PEM" | base64 -w0)

# Find all values.yaml files containing RSA_PUBLIC_KEY and update them
changed=0
while IFS= read -r file; do
  current=$(grep 'RSA_PUBLIC_KEY:' "$file" | sed 's/.*RSA_PUBLIC_KEY: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' ')
  if [[ "$current" == "$B64" ]]; then
    echo "✓ ${file#"$REPO_ROOT"/}: unchanged"
  else
    sed -i "s|RSA_PUBLIC_KEY: .*|RSA_PUBLIC_KEY: \"$B64\"|" "$file"
    echo "✎ ${file#"$REPO_ROOT"/}: updated"
    changed=1
  fi
done < <(grep -rl 'RSA_PUBLIC_KEY:' "$APPS_DIR" --include='*.yaml')

if [[ $changed -eq 0 ]]; then
  echo "No changes needed."
else
  echo ""
  echo "RSA_PUBLIC_KEY updated. Review with: git diff"
fi
