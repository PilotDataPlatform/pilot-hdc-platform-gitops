# pilot-hdc-platform-gitops
GitOps repository that contains all the related configuration to manage the Pilot-HDC kubernetes clusters

## App-of-Apps Pattern

This repo uses ArgoCD's app-of-apps pattern: a root Application (`root-app.yaml`) deploys all child Applications, each defined under `clusters/dev/apps/<name>/`.

### Sync-Wave Order

| Wave | App | Notes |
|------|-----|-------|
| 2 | external-secrets | Operator + CRDs |
| 3 | vault | Deploys Vault server |
| 3 | registry-secrets | ExternalSecrets for docker-registry-secret |
| 4 | postgresql | Main DB (utility ns) |
| 4 | keycloak-postgresql | Keycloak DB |
| 5 | redis | |
| 5 | kafka | Broker + Zookeeper + Connect |
| 5 | minio | Object storage with built-in encryption |
| 6 | keycloak | |
| 7 | auth | |
| 8 | metadata | |
| 8 | project | |
| 8 | kong-postgresql | Kong DB (split from kong for PreSync hook) |
| 9 | kong | API gateway |
| 10 | bff | Backend-for-frontend |

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
| `secret/postgresql` | postgres-password, {metadata,project,auth,dataops}-user-password | postgresql init-job |
| `secret/keycloak` | admin-password, postgres-password | keycloak |
| `secret/redis` | password | redis, bff |
| `secret/auth` | keycloak-client-secret | auth service |
| `secret/docker-registry/ovh` | username, password | registry-secrets |

## Acknowledgements
The development of the HealthDataCloud open source software was supported by the EBRAINS research infrastructure, funded from the European Union's Horizon 2020 Framework Programme for Research and Innovation under the Specific Grant Agreement No. 945539 (Human Brain Project SGA3) and H2020 Research and Innovation Action Grant Interactive Computing E-Infrastructure for the Human Brain Project ICEI 800858.

This project has received funding from the European Union’s Horizon Europe research and innovation programme under grant agreement No 101058516. Views and opinions expressed are however those of the author(s) only and do not necessarily reflect those of the European Union or other granting authorities. Neither the European Union nor other granting authorities can be held responsible for them.

![EU HDC Acknowledgement](https://hdc.humanbrainproject.eu/img/HDC-EU-acknowledgement.png)
