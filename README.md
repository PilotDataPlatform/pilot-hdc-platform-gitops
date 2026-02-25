# pilot-hdc-platform-gitops
GitOps repository that contains all the related configuration to manage the Pilot-HDC kubernetes clusters

## App-of-Apps Pattern

This repo uses ArgoCD's app-of-apps pattern: a root Application (`root-app.yaml`) deploys all child Applications, each defined under `clusters/dev/apps/<name>/`.

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
| 4 | postgresql | Main DB (utility ns) |
| 4 | keycloak-postgresql | Keycloak DB |
| 5 | redis | |
| 5 | kafka | Broker + Zookeeper + Connect |
| 5 | elasticsearch | ES 7.17.3 (utility ns) |
| 5 | mailhog | SMTP sink for dev (no auth, no ingress) |
| 5 | minio | Object storage, S3 API ingress at `object.dev.hdc.ebrains.eu` |
| 5 | message-bus-greenroom | RabbitMQ (greenroom ns) |
| 6 | keycloak | |
| 7 | auth | |
| 8 | metadata | |
| 8 | project | |
| 8 | dataset | Dataset management (S3, metadata) |
| 8 | dataops | Data operations (lineage, file ops) |
| 8 | notification | Email notifications (uses MailHog SMTP) |
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

**Note**: `registry-secrets` (wave 3) will show `SecretSyncError` until Vault is unsealed and the ClusterSecretStore can connect to it — expected on first deploy, resolves via `selfHeal: true`.

### Prerequisites
- Vault must be unsealed and initialized before apps in wave 3+ can sync

## Vault Bootstrap (One-Time)

After ArgoCD deploys Vault, these manual steps are required once per cluster.

### Initialize & Unseal

```bash
# Initialize - outputs 5 unseal keys + root token
kubectl exec -it vault-0 -n vault -- vault operator init

# Store keys securely (dev cluster uses gopass), e.g:
# gopass ebrains-dev/hdc/ovh/vault-unseal-keys

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
# Create test secret
vault kv put secret/test foo=bar

# Check ESO synced it (ClusterSecretStore "vault" is pre-configured)
kubectl get externalsecret -A
```

## Required Vault Secrets

These secrets must exist in Vault before the corresponding apps can sync.

### MinIO (`secret/minio`)

```bash
# Generate 256-bit encryption key
ENCRYPTION_KEY=$(openssl rand -base64 32)

vault kv put secret/minio \
  access_key="minio-admin" \
  secret_key="$(openssl rand -hex 16)" \
  kms_secret_key="minio-encryption-key:${ENCRYPTION_KEY}"
```

**Important**: Back up `kms_secret_key` - losing it means losing access to encrypted data.

### Other Secrets

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
| `secret/docker-registry/ovh` | username, password | registry-secrets |

To add or update a service password: `vault kv patch secret/postgresql <service>-user-password=<value>`

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

**High-level data flow**: Portal → BFF → Kong (API gateway) → HDC microservices → backing stores (PostgreSQL, Redis, Kafka, Elasticsearch, MinIO). Files land in the `greenroom` zone first, move to `core` after approval. Keycloak handles authentication, Vault stores all secrets synced via ESO.

## Development

### Prerequisites

- [Helm](https://helm.sh/) 3.x
- [yq](https://github.com/mikefarah/yq) v4+
- `make`
- `kubectl` (for cluster operations)
- `vault` CLI (for secret management)

### Version Management

All image tags and chart dependency versions are centralized in [`clusters/dev/versions.yaml`](clusters/dev/versions.yaml).

```bash
# 1. Edit versions.yaml (image tag or chart version)
vim clusters/dev/versions.yaml

# 2. For chart version changes, propagate to Chart.yaml files
make sync-versions

# 3. Validate
make test

# 4. Commit both versions.yaml and any updated Chart.yaml files
```

Image tags are consumed as a Helm valueFile — ArgoCD deep-merges `registry.yaml → versions.yaml → values.yaml`. Chart dependency versions can't be set via Helm values, so `make sync-versions` bridges the gap by updating each `Chart.yaml` via yq.

### Registry Switching

The repo supports multiple container registries (OVH, EBRAINS). The active registry is set in `clusters/dev/registry.yaml`.

```bash
make which-registry              # show current registry
make switch-registry TO=ovh      # switch to OVH registry
make switch-registry TO=ebrains  # switch to EBRAINS registry
```

This updates `registry.yaml` and rewrites hardcoded registry URLs in app `values.yaml` files.

### Validation

Run `make test` before committing. It runs all checks:

| Test | What it catches |
|------|----------------|
| `helm-test-eso` | ESO template variables not preserved (Helm eating `{{ }}`) |
| `helm-test-image` | Images pulling from wrong registry |
| `helm-test-versions` | Image tags not matching `versions.yaml` |
| `helm-test-envdup` | Duplicate env vars (rejected by ServerSideApply) |
| `helm-test-pullsecrets` | Missing `imagePullSecrets` on pod specs |
| `helm-test-envvars-rendered` | Env vars defined in values but not rendered by chart |
| `helm-test-regsecret-coverage` | Namespaces missing docker-registry-secret |

### Additional Resources

- [`docs/`](docs/) — Operational scripts and runbooks (e.g., PostgreSQL validation)

## Acknowledgements
The development of the HealthDataCloud open source software was supported by the EBRAINS research infrastructure, funded from the European Union's Horizon 2020 Framework Programme for Research and Innovation under the Specific Grant Agreement No. 945539 (Human Brain Project SGA3) and H2020 Research and Innovation Action Grant Interactive Computing E-Infrastructure for the Human Brain Project ICEI 800858.

This project has received funding from the European Union’s Horizon Europe research and innovation programme under grant agreement No 101058516. Views and opinions expressed are however those of the author(s) only and do not necessarily reflect those of the European Union or other granting authorities. Neither the European Union nor other granting authorities can be held responsible for them.

![EU HDC Acknowledgement](https://hdc.humanbrainproject.eu/img/HDC-EU-acknowledgement.png)
