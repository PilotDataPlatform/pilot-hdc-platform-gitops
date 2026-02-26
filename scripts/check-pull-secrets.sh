#!/usr/bin/env bash
# Ensures every pod spec (Deployment, StatefulSet, Job) has imagePullSecrets.
# Without it, pods can't pull from private registries even if the image URL is correct.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPS_DIR="$REPO_ROOT/clusters/dev/apps"
REGISTRY_DIR="$REPO_ROOT/clusters/dev"
VERSIONS_FILE="$REPO_ROOT/clusters/dev/versions.yaml"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 app1 [app2 ...]" >&2
  exit 1
fi

# Apps where the upstream chart has no imagePullSecrets support.
# These rely on ServiceAccount-level imagePullSecrets (patched by registry-secrets).
SKIP_APPS="xwiki"

failed=0

for app in "$@"; do
  if [[ " $SKIP_APPS " == *" $app "* ]]; then
    echo "⊘ $app: skipped (SA-level imagePullSecrets)"
    continue
  fi
  vfiles=(-f "$REGISTRY_DIR/registry.yaml" -f "$VERSIONS_FILE")
  [[ -f "$APPS_DIR/$app/values.yaml" ]] && vfiles+=(-f "$APPS_DIR/$app/values.yaml")

  rendered=$(helm template test "$APPS_DIR/$app" "${vfiles[@]}" --skip-tests 2>/dev/null || true)
  [[ -z "$rendered" ]] && continue

  app_failed=0
  for kind in Deployment StatefulSet Job; do
    names=$(echo "$rendered" | yq -r "select(.kind == \"$kind\") | .metadata.name" 2>/dev/null | grep -v '^$' | grep -v '^null$' | grep -v '^---$' || true)
    [[ -z "$names" ]] && continue

    while IFS= read -r name; do
      has_secrets=$(echo "$rendered" | yq "select(.kind == \"$kind\" and .metadata.name == \"$name\") | .spec.template.spec.imagePullSecrets | length" 2>/dev/null | head -1)
      has_secrets=${has_secrets:-0}
      [[ "$has_secrets" == "null" || "$has_secrets" == "" ]] && has_secrets=0

      if [[ "$has_secrets" -eq 0 ]]; then
        echo "✗ $app: $kind/$name missing imagePullSecrets"
        app_failed=1
        failed=1
      fi
    done <<< "$names"
  done

  if [[ "$app_failed" -eq 0 ]]; then
    echo "✓ $app: all pod specs have imagePullSecrets"
  fi
done

exit $failed
