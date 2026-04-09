#!/usr/bin/env bash
# Validates env vars defined in values.yaml are rendered in helm template.
# Catches chart bugs where extraEnvVars/envVars aren't picked up (e.g., Kong migration job).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${ENV:-dev}"
APPS_DIR="$REPO_ROOT/clusters/$ENV/apps"
REGISTRY_DIR="$REPO_ROOT/clusters/$ENV"
VERSIONS_FILE="$REPO_ROOT/clusters/$ENV/versions.yaml"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 app1 [app2 ...]" >&2
  exit 1
fi

failed=0

for app in "$@"; do
  vfile="$APPS_DIR/$app/values.yaml"
  [[ -f "$vfile" ]] || continue

  # Find env var definitions: arrays with {name: X, value: Y}
  # Works for extraEnvVars, envVars, env, migration.extraEnvVars, etc.
  defined=$(yq '.. | select(type == "!!seq") | .[] | select(has("name") and has("value")) | .name' "$vfile" 2>/dev/null | sort -u)
  if [[ -z "$defined" ]]; then
    echo "⊘ $app: no env vars defined (skipped)"
    continue
  fi

  # Build valueFiles list (matches ArgoCD application.yaml patterns)
  vfiles=(-f "$REGISTRY_DIR/registry.yaml" -f "$VERSIONS_FILE")
  vfiles+=(-f "$vfile")

  # Render template
  rendered=$(helm template test "$APPS_DIR/$app" "${vfiles[@]}" --skip-tests 2>/dev/null || true)

  # Extract all env var names from rendered manifests
  rendered_envs=$(echo "$rendered" | yq '.. | select(has("env")) | .env[].name' 2>/dev/null | sort -u)

  app_failed=0
  for var in $defined; do
    if echo "$rendered_envs" | grep -qx "$var"; then
      echo "✓ $app: $var"
    else
      echo "✗ $app: $var defined but NOT rendered"
      app_failed=1
      failed=1
    fi
  done

  [[ $app_failed -eq 0 ]] || echo "  ^ check if chart supports this env var location"
done

exit $failed
