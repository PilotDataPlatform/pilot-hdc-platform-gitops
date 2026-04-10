# pilot-hdc-platform-gitops
GitOps repository that contains all the related configuration to manage the Pilot-HDC kubernetes clusters

## App-of-Apps Pattern

This repo uses ArgoCD's app-of-apps pattern: a root Application (`root-app.yaml`) deploys all child Applications, each defined under `clusters/<env>/apps/<name>/`.

> **Environments:** Replace `<env>` with `dev` or `prod` throughout. Domains: dev -> `dev.hdc.ebrains.eu`, prod -> `hdc.ebrains.eu`.

### Sync-Wave Order

| Wave | App | Notes |
|------|-----|-------|
| -1 | argo-cd | GitOps controller |
| 0 | cert-manager | TLS certificate management |
| 1 | ingress-nginx | Ingress controller |
| 2 | external-secrets | Operator + CRDs |
| 2 | nfs-provisioner | NFS StorageClass for RWX PVCs |
| 3 | vault | Deploys Vault server |
| 3 | registry-secrets | ExternalSecrets for docker-registry-secret |
| 3 | greenroom-storage | RWX PVC for upload/download (greenroom ns, nfs-client) |
| 3 | core-storage | RWX PVC for upload/download (core ns, nfs-client) |
| 3 | arc-controller | GitHub Actions Runner Controller (arc-systems ns, dev only) |
| 4 | arc-runners-public | Self-hosted GH runners for PilotDataPlatform org (DinD, arc-runners ns, dev only) |
| 4 | postgresql | Main DB (utility ns) |
| 4 | keycloak-postgresql | Keycloak DB |
| 5 | redis | |
| 5 | kafka | Broker + Zookeeper + Connect |
| 5 | elasticsearch | ES 7.17.3 (utility ns) |
| 5 | mailhog | SMTP sink (dev only, no auth, no ingress) |
| 5 | minio | Object storage, S3 API ingress at `object.<domain>` |
| 5 | message-bus-greenroom | RabbitMQ (greenroom ns) |
| 6 | keycloak | |
| 7 | auth | |
| 8 | metadata | |
| 8 | project | |
| 8 | dataset | Dataset management (S3, metadata) |
| 8 | dataops | Data operations (lineage, file ops) |
| 8 | notification | Email notifications (dev: MailHog SMTP; prod: real SMTP) |
| 8 | approval | Copy request workflows |
| 8 | kong-postgresql | Kong DB (split from kong for PreSync hook) |
| 8 | queue-consumer | Queue consumer (greenroom ns) |
| 8 | queue-producer | Queue producer (greenroom ns) |
| 8 | queue-socketio | Queue WebSocket notifications |
| 8 | pipelinewatch | Pipeline status watcher |
| 8 | upload-greenroom | Upload service (greenroom ns) |
| 8 | upload-core | Upload service (core ns) |
| 8 | download-greenroom | Download service (greenroom ns) |
| 8 | download-core | Download service (core ns) |
| 8 | search | Search service (ES-backed) |
| 9 | kong | API gateway |
| 9 | metadata-event-handler | Kafka→ES event indexer |
| 9 | kg-integration | EBRAINS Knowledge Graph integration |
| 10 | bff | Backend-for-frontend (web) |
| 10 | bff-cli | Backend-for-frontend (CLI) |
| 11 | portal | Frontend UI |
| 12 | workspace | Workspace orchestration service |
| 13 | guacamole-{project} | Per-project Guacamole stack (ApplicationSet) |

**Note**: `registry-secrets` (wave 3) will show `SecretSyncError` until Vault is unsealed and the ClusterSecretStore can connect to it — expected on first deploy, resolves via `selfHeal: true`.

### Workbench (Per-Project ApplicationSets)

Workbench services are deployed per project namespace (`project-{name}`) using ArgoCD ApplicationSets with a git file generator. Each project is defined in `clusters/<env>/workbench/projects/{name}.yaml`:

```yaml
name: myproject
```

Adding a project file triggers ApplicationSets to create per-project instances of each workbench service. Currently deployed:

| Service | Chart | Components |
|---------|-------|------------|
| Guacamole | `clusters/<env>/workbench/guacamole-stack/` | guacd + guacamole + PostgreSQL (md5 auth) |

The `projects/` directory is shared across all workbench ApplicationSets within an environment — future services (Superset, JupyterHub) will read from the same catalog.

#### Adding a new project

1. Create `clusters/<env>/workbench/projects/<name>.yaml` with `name: <name>`
2. Ensure prerequisites exist:
   - Vault secret: `vault kv put secret/guacamole pg-password=$(openssl rand -hex 24)`
   - Keycloak client: `guacamole-<name>` (managed in Terraform)
3. Commit and push to `main` — ArgoCD creates all per-project Applications automatically

Each project gets: namespace `project-<name>`, its own PostgreSQL, ESO secrets, and ingress at `/workbench/<name>/guacamole/`.

#### Removing a project

Removing a project file does **not** delete the ArgoCD Application or its resources (`applicationsSync: create-update`). To fully decommission:

1. Delete the project file and push
2. Delete the Application in ArgoCD (resources become orphaned)
3. Manual cleanup: `kubectl delete ns project-<name>`

**Safety**: `prune: false` on generated Applications — no accidental PVC/StatefulSet deletion. No finalizers on stateful apps.

### Prerequisites
- Vault must be unsealed and initialized before apps in wave 3+ can sync

## Vault Bootstrap (One-Time)

After ArgoCD deploys Vault, these manual steps are required once per cluster.

### Initialize & Unseal

```bash
# Initialize - outputs 5 unseal keys + root token
kubectl exec -it vault-0 -n vault -- vault operator init

# Store keys securely in gopass:
#   dev:  gopass ebrains-dev/hdc/ovh/vault-unseal-keys
#   prod: gopass ebrains/hdc/ovh/vault-unseal-keys

# Unseal (repeat 3x with different keys)
kubectl exec -it vault-0 -n vault -- vault operator unseal
```

### Configure K8s Auth for External Secrets Operator

```bash
# Port-forward to Vault
kubectl port-forward -n vault svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
vault login  # paste root token

# Enable K8s auth
vault auth enable kubernetes

# Configure K8s auth endpoint
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"

# Enable KV v2 secrets engine
vault secrets enable -path=secret kv-v2

# Create read-only policy for ESO
vault policy write external-secrets - <<EOF
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

# Create role bound to ESO service account
vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=1h
```

### Verify Integration

```bash
vault kv put secret/test foo=bar
vault kv get secret/test

# Check ESO synced it (ClusterSecretStore "vault" is pre-configured)
kubectl get externalsecret -A

# Clean up
vault kv delete secret/test
```

## Required Vault Secrets

These secrets must exist in Vault before the corresponding apps can sync. See [`docs/vault-secrets.md`](docs/vault-secrets.md) for ready-to-run provisioning commands.

| Path | Keys | Used By |
|------|------|---------|
| `secret/postgresql` | postgres-password, {metadata,project,auth,dataops,dataset,notification,approval,kg-integration}-user-password | postgresql, init-job, metadata, project, auth, dataops, dataset, notification, approval, kg-integration |
| `secret/minio` | access_key, secret_key, kms_secret_key | minio, bff, dataset, queue-consumer, upload-greenroom, upload-core, download-greenroom, download-core |
| `secret/keycloak` | admin-password, postgres-password | keycloak, keycloak-postgresql |
| `secret/redis` | password | redis, auth, bff, bff-cli, dataops, approval, dataset, queue-consumer, upload-greenroom, upload-core |
| `secret/auth` | keycloak-client-secret | auth |
| `secret/approval` | db-uri | approval init container (psql + alembic) |
| `secret/kong` | postgres-password, postgres-user | kong-postgresql |
| `secret/rabbitmq` | username, password | message-bus-greenroom, queue-consumer, queue-producer, queue-socketio |
| `secret/download` | download-key | download-greenroom, download-core |
| `secret/kg-integration` | account-secret | kg-integration |
| `secret/bff-cli` | cli-secret, atlas-password, guacamole-jwt-public-key | bff-cli |
| `secret/guacamole` | pg-password | guacamole-stack (PG admin + app user, per-project) |
| `secret/docker-registry/ovh` | username, password | registry-secrets |
| `secret/github-runner` | github_app_id, github_app_installation_id, github_app_private_key | arc-runners-public |

## Platform Architecture (WIP)

HDC splits workloads across namespaces by trust boundary and function:

| Namespace | Purpose | Key Services |
|-----------|---------|-------------|
| `utility` | Most HDC services + shared infra | auth, metadata, project, dataops, dataset, approval, notification, search, bff, bff-cli, portal, kong, postgresql, kafka, elasticsearch, mailhog, kong-postgresql |
| `greenroom` | Pre-approval zone (untrusted data) | upload, download, queue-consumer/producer/socketio, pipelinewatch, RabbitMQ, RWX PVC |
| `core` | Post-approval zone (approved data) | upload, download, RWX PVC |
| `keycloak` | Identity provider | Keycloak + dedicated PostgreSQL |
| `vault` | Secrets management | HashiCorp Vault |
| `minio` | Object storage | MinIO (S3-compatible) |
| `redis` | Cache/session store | Redis |
| `argocd` | GitOps controller | ArgoCD |
| `ingress-nginx` | Ingress | NGINX ingress controller |
| `cert-manager` | TLS | cert-manager |
| `external-secrets` | Secret sync | External Secrets Operator → Vault |
| `nfs-provisioner` | Storage | NFS StorageClass for RWX PVCs |
| `arc-systems` | CI runner controller | ARC (actions-runner-controller) |
| `arc-runners` | CI runner pods | Self-hosted GitHub Actions runners (DinD) |
| `project-{name}` | Per-project workbench | Guacamole (guacd + webapp + PG) — one ns per project |

**High-level data flow**: Portal → BFF → Kong (API gateway) → HDC microservices → backing stores (PostgreSQL, Redis, Kafka, Elasticsearch, MinIO). Files land in the `greenroom` zone first, move to `core` after approval. Keycloak handles authentication, Vault stores all secrets synced via ESO.

## Development

### Prerequisites

- [Helm](https://helm.sh/) 3.x
- [yq](https://github.com/mikefarah/yq) v4+
- `make`
- `kubectl` (for cluster operations)
- `vault` CLI (for secret management)

### Version Management

All image tags and chart dependency versions are centralized in `clusters/<env>/versions.yaml`.

```bash
# 1. Edit versions.yaml (image tag or chart version)
vim clusters/<env>/versions.yaml

# 2. For chart version changes, propagate to Chart.yaml files
make ENV=<env> sync-versions

# 3. Validate
make ENV=<env> test

# 4. Commit both versions.yaml and any updated Chart.yaml files
```

Image tags are consumed as a Helm valueFile — ArgoCD deep-merges `registry.yaml → versions.yaml → values.yaml`. Chart dependency versions can't be set via Helm values, so `make sync-versions` bridges the gap by updating each `Chart.yaml` via yq.

### Registry Switching

The repo supports multiple container registries (OVH, EBRAINS). The active registry is set in `clusters/<env>/registry.yaml`.

```bash
make ENV=<env> which-registry              # show current registry
make ENV=<env> switch-registry TO=ovh      # switch to OVH registry
make ENV=<env> switch-registry TO=ebrains  # switch to EBRAINS registry
```

This updates `registry.yaml` and rewrites hardcoded registry URLs in app `values.yaml` files.

### Validation

Run `make ENV=<env> test` before committing. It runs all checks:

| Test | What it catches |
|------|----------------|
| `helm-test-eso` | ESO template variables not preserved (Helm eating `{{ }}`) |
| `helm-test-image` | Images pulling from wrong registry |
| `helm-test-versions` | Image tags not matching `versions.yaml` |
| `helm-test-envdup` | Duplicate env vars (rejected by ServerSideApply) |
| `helm-test-pullsecrets` | Missing `imagePullSecrets` on pod specs |
| `helm-test-envvars-rendered` | Env vars defined in values but not rendered by chart |
| `helm-test-regsecret-coverage` | Namespaces missing docker-registry-secret |
| `helm-test-workbench` | Workbench charts: images, ESO vars, imagePullSecrets |

### Additional Resources

- [`docs/`](docs/) — Operational scripts and runbooks (e.g., PostgreSQL validation)

## Acknowledgements
The development of the HealthDataCloud open source software was supported by the EBRAINS research infrastructure, funded from the European Union's Horizon 2020 Framework Programme for Research and Innovation under the Specific Grant Agreement No. 945539 (Human Brain Project SGA3) and H2020 Research and Innovation Action Grant Interactive Computing E-Infrastructure for the Human Brain Project ICEI 800858.

This project has received funding from the European Union’s Horizon Europe research and innovation programme under grant agreement No 101058516. Views and opinions expressed are however those of the author(s) only and do not necessarily reflect those of the European Union or other granting authorities. Neither the European Union nor other granting authorities can be held responsible for them.

![EU HDC Acknowledgement](https://hdc.ebrains.eu/img/HDC-EU-acknowledgement.png)
