#!/usr/bin/env bash
# Ensures every namespace that apps deploy to has a docker-registry-secret
# ExternalSecret in the registry-secrets template. Catches the case where
# a new namespace is introduced but registry-secrets isn't updated.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPS_DIR="$REPO_ROOT/clusters/dev/apps"
REGISTRY_DIR="$REPO_ROOT/clusters/dev"
VERSIONS_FILE="$REPO_ROOT/clusters/dev/versions.yaml"
REG_SECRET_TMPL="$APPS_DIR/registry-secrets/templates/docker-registry-secret.yaml"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 app1 [app2 ...]" >&2
  exit 1
fi

# Extract namespaces covered by registry-secrets template
covered=$(grep -oP '"[^"]+"' "$REG_SECRET_TMPL" | head -1 | tr -d '"' || true)
# Parse the list from the range line: {{- range $ns := list "ns1" "ns2" ... }}
covered=$(sed -n 's/.*range.*list\s\+//p' "$REG_SECRET_TMPL" | tr -d '{}' | grep -oP '"[^"]+"' | tr -d '"')

failed=0

for app in "$@"; do
  # Skip registry-secrets itself and apps without imagePullSecrets
  [[ "$app" == "registry-secrets" ]] && continue

  vfiles=(-f "$REGISTRY_DIR/registry.yaml" -f "$VERSIONS_FILE")
  [[ -f "$APPS_DIR/$app/values.yaml" ]] && vfiles+=(-f "$APPS_DIR/$app/values.yaml")

  rendered=$(helm template test "$APPS_DIR/$app" "${vfiles[@]}" --skip-tests 2>/dev/null || true)
  [[ -z "$rendered" ]] && continue

  # Check if this app uses docker-registry-secret
  uses_secret=$(echo "$rendered" | grep -c 'docker-registry-secret' || true)
  [[ "$uses_secret" -eq 0 ]] && continue

  # Get the namespace from the ArgoCD Application spec
  ns=""
  if [[ -f "$APPS_DIR/$app/application.yaml" ]]; then
    ns=$(yq '.spec.destination.namespace' "$APPS_DIR/$app/application.yaml" 2>/dev/null || true)
  fi
  [[ -z "$ns" || "$ns" == "null" ]] && continue

  if echo "$covered" | grep -qx "$ns"; then
    echo "✓ $app: namespace '$ns' covered by registry-secrets"
  else
    echo "✗ $app: namespace '$ns' NOT in registry-secrets template"
    failed=1
  fi
done

exit $failed
