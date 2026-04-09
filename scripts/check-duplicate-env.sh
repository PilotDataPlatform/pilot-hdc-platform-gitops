#!/usr/bin/env bash
# Detects duplicate env var names in rendered Helm deployments.
# ServerSideApply rejects these, but helm template doesn't catch them.
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
  # Build valueFiles list (some apps don't have all files)
  vfiles=(-f "$REGISTRY_DIR/registry.yaml" -f "$VERSIONS_FILE")
  [[ -f "$APPS_DIR/$app/values.yaml" ]] && vfiles+=(-f "$APPS_DIR/$app/values.yaml")

  rendered=$(helm template test "$APPS_DIR/$app" "${vfiles[@]}" --skip-tests 2>/dev/null || true)

  # Skip apps without Deployments
  if [[ -z "$rendered" ]] || ! echo "$rendered" | yq -e 'select(.kind == "Deployment")' &>/dev/null; then
    echo "⊘ $app: no Deployment (skipped)"
    continue
  fi

  # For each Deployment, check init and main containers for duplicate env names
  app_dupes=""
  for path in "initContainers" "containers"; do
    count=$(echo "$rendered" | yq "select(.kind == \"Deployment\") | .spec.template.spec.$path | length" 2>/dev/null)
    count=${count:-0}
    [[ "$count" == "null" || "$count" == "" ]] && count=0
    for ((i=0; i<count; i++)); do
      cname=$(echo "$rendered" | yq "select(.kind == \"Deployment\") | .spec.template.spec.${path}[$i].name" 2>/dev/null)
      dupes=$(echo "$rendered" | yq -r "select(.kind == \"Deployment\") | .spec.template.spec.${path}[$i].env[].name" 2>/dev/null \
        | sort | uniq -d)
      if [[ -n "$dupes" ]]; then
        while IFS= read -r var; do
          app_dupes+="    ${cname}: ${var}"$'\n'
        done <<< "$dupes"
      fi
    done
  done

  if [[ -n "$app_dupes" ]]; then
    echo "✗ $app: duplicate env vars:"
    printf "%s" "$app_dupes"
    failed=1
  else
    echo "✓ $app: no duplicate env vars"
  fi
done

exit $failed
