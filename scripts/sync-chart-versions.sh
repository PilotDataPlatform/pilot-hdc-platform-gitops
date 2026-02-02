#!/usr/bin/env bash
# Syncs chart dependency versions from clusters/dev/versions.yaml into each app's Chart.yaml
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS_FILE="$REPO_ROOT/clusters/dev/versions.yaml"
APPS_DIR="$REPO_ROOT/clusters/dev/apps"

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required. Install: https://github.com/mikefarah/yq" >&2
  exit 1
fi

# Map chart name → app directory(ies)
declare -A CHART_TO_DIRS=(
  [argo-cd]="argo-cd"
  [auth-service]="auth"
  [metadata-service]="metadata"
  [cert-manager-jetstack]="cert-manager"
  [external-secrets]="external-secrets"
  [ingress-nginx]="ingress-nginx"
  [keycloak]="keycloak"
  [postgresql]="postgresql keycloak-postgresql"
  [redis]="redis"
  [vault]="vault"
)

changed=0

for chart in $(yq '.charts | keys | .[]' "$VERSIONS_FILE"); do
  version=$(yq ".charts.\"$chart\"" "$VERSIONS_FILE")
  dirs="${CHART_TO_DIRS[$chart]:-}"

  if [[ -z "$dirs" ]]; then
    echo "WARN: no directory mapping for chart '$chart'" >&2
    continue
  fi

  for dir in $dirs; do
    chart_yaml="$APPS_DIR/$dir/Chart.yaml"
    if [[ ! -f "$chart_yaml" ]]; then
      echo "WARN: $chart_yaml not found, skipping" >&2
      continue
    fi

    current=$(yq ".dependencies[] | select(.name == \"$chart\") | .version" "$chart_yaml")
    if [[ "$current" == "$version" ]]; then
      echo "✓ $dir/$chart: $version (unchanged)"
    else
      yq -i "(.dependencies[] | select(.name == \"$chart\")).version = \"$version\"" "$chart_yaml"
      echo "✎ $dir/$chart: $current → $version"
      changed=1
    fi
  done
done

if [[ $changed -eq 1 ]]; then
  echo ""
  echo "Chart versions updated. Run 'make helm-deps' to fetch updated chart dependencies."
fi
