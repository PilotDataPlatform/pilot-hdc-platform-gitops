#!/bin/bash
# Deploy pilotcli binary to shared-tools NFS PVC in all project namespaces.
# Discovers projects dynamically from clusters/dev/workbench/projects/*.yaml.
# Run from repo root.

set -euo pipefail

PILOTCLI_VERSION="2.2.7-hdc"
PILOTCLI_PATH="/tmp/pilotcli"
COPY_DESTINATION="/opt/shared"
OWNER="PilotDataPlatform"
REPO="cli"
PROJECTS_DIR="clusters/dev/workbench/projects"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Discover project namespaces from projects/*.yaml
NAMESPACES=()
for f in "$PROJECTS_DIR"/*.yaml; do
  name=$(grep '^name:' "$f" | awk '{print $2}')
  [[ -n "$name" ]] && NAMESPACES+=("project-$name")
done

if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
  echo "No projects found in $PROJECTS_DIR"
  exit 1
fi

echo "Projects: ${NAMESPACES[*]}"

# Download pilotcli binary (public repo, no token needed)
API_URL="https://api.github.com/repos/$OWNER/$REPO"
ASSET_ID=$(curl -sf "$API_URL/releases/tags/$PILOTCLI_VERSION" | jq -r '.assets[0].id')
if [[ "$ASSET_ID" == "null" || -z "$ASSET_ID" ]]; then
  echo "Asset not found for release $PILOTCLI_VERSION"
  exit 1
fi

echo "Downloading pilotcli $PILOTCLI_VERSION (asset $ASSET_ID)..."
curl -fsSL -H "Accept: application/octet-stream" "$API_URL/releases/assets/$ASSET_ID" -o "$PILOTCLI_PATH"
chmod +x "$PILOTCLI_PATH"

# Temp manifest for busybox pod (uses docker-registry-secret already in each project-* namespace)
BUSYBOX_MANIFEST=$(mktemp /tmp/busybox-XXXXXX.yaml)
trap 'rm -f "$BUSYBOX_MANIFEST"' EXIT

cat > "$BUSYBOX_MANIFEST" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pilotcli-copy
spec:
  selector:
    matchLabels:
      app: pilotcli-copy
  replicas: 1
  template:
    metadata:
      labels:
        app: pilotcli-copy
    spec:
      terminationGracePeriodSeconds: 5
      volumes:
        - name: shared-tools
          persistentVolumeClaim:
            claimName: shared-tools
      containers:
        - name: busybox
          image: busybox:1.36.0
          command: ["/bin/sh"]
          stdin: true
          tty: true
          volumeMounts:
            - mountPath: "/opt/shared"
              name: shared-tools
EOF

for NS in "${NAMESPACES[@]}"; do
  echo "--- $NS ---"
  kubectl apply -f "$BUSYBOX_MANIFEST" -n "$NS"

  echo "Waiting for pod..."
  kubectl rollout status deployment/pilotcli-copy -n "$NS" --timeout=60s

  POD=$(kubectl get pods -n "$NS" -l app=pilotcli-copy -o jsonpath='{.items[0].metadata.name}')
  kubectl cp "$PILOTCLI_PATH" "$NS/$POD:$COPY_DESTINATION/pilotcli"

  kubectl delete deployment pilotcli-copy -n "$NS"
  echo "Done: $NS"
done

echo "pilotcli $PILOTCLI_VERSION deployed to all project namespaces."
