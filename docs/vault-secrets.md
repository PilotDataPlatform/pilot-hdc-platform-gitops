# Vault Secret Provisioning

Ready-to-run commands for provisioning all required Vault secrets. Run these after Vault is bootstrapped (see main README).

> **Per-environment**: each cluster has its own Vault instance. Run these commands against the target cluster's Vault (port-forward + `vault login` first).

## PostgreSQL (`secret/postgresql`)

```bash
vault kv put secret/postgresql \
  postgres-password=$(openssl rand -hex 24) \
  metadata-user-password=$(openssl rand -hex 24) \
  project-user-password=$(openssl rand -hex 24) \
  auth-user-password=$(openssl rand -hex 24) \
  dataops-user-password=$(openssl rand -hex 24) \
  notification-user-password=$(openssl rand -hex 24) \
  dataset-user-password=$(openssl rand -hex 24) \
  approval-user-password=$(openssl rand -hex 24) \
  kg-integration-user-password=$(openssl rand -hex 24)
```

To add or update a single service password:

```bash
vault kv patch secret/postgresql <service>-user-password=$(openssl rand -hex 24)
```

## Keycloak (`secret/keycloak`)

```bash
vault kv put secret/keycloak \
  admin-password=$(openssl rand -hex 24) \
  postgres-password=$(openssl rand -hex 24) \
  keycloak-user-password=$(openssl rand -hex 24) \
  github-token='<github-pat-with-packages-read-scope>'
```

## Redis (`secret/redis`)

```bash
vault kv put secret/redis \
  password=$(openssl rand -hex 24)
```

**Use hex only** (`rand -hex`, not `rand -base64`). Some HDC services build `redis://` URIs without URL-encoding — base64 chars (`+`, `/`, `=`) break parsing.

## MinIO (`secret/minio`)

```bash
ENCRYPTION_KEY=$(openssl rand -base64 32)

vault kv put secret/minio \
  access_key="minio-admin" \
  secret_key="$(openssl rand -hex 16)" \
  kms_secret_key="minio-encryption-key:${ENCRYPTION_KEY}"
```

**Important**: Back up `kms_secret_key` — losing it means losing access to encrypted data.

## RabbitMQ (`secret/rabbitmq`)

```bash
vault kv put secret/rabbitmq \
  username="greenroom" \
  password=$(openssl rand -hex 24)
```

## Docker Registry (`secret/docker-registry/ovh`)

```bash
vault kv put secret/docker-registry/ovh \
  username='<registry-robot-account>' \
  password='<registry-robot-token>'
```

## Auth (`secret/auth`)

```bash
vault kv put secret/auth \
  keycloak-client-secret='<client-secret-from-keycloak>' \
  freeipa-password='<freeipa-service-account-password>'
```

## Kong (`secret/kong`)

```bash
vault kv put secret/kong \
  postgres-user="kong" \
  postgres-password=$(openssl rand -hex 24)
```

## Approval (`secret/approval`)

```bash
vault kv put secret/approval \
  db-uri='postgresql://approval_user:<password>@postgres.utility.svc:5432/approval'
```

Replace `<password>` with the `approval-user-password` from `secret/postgresql`.

## Download (`secret/download`)

```bash
vault kv put secret/download \
  download-key=$(openssl rand -hex 32)
```

## KG Integration (`secret/kg-integration`)

```bash
vault kv put secret/kg-integration \
  account-secret='<kg-service-account-secret>'
```

## BFF CLI (`secret/bff-cli`)

```bash
vault kv put secret/bff-cli \
  cli-secret='<cli-client-secret>' \
  atlas-password='<atlas-password>' \
  guacamole-jwt-public-key='<public-key-pem>'
```

## Guacamole (`secret/guacamole`)

```bash
vault kv put secret/guacamole \
  pg-password=$(openssl rand -hex 24)
```

## GitHub Runner (`secret/github-runner`) — dev only

```bash
vault kv put secret/github-runner \
  github_app_id='<app-id>' \
  github_app_installation_id='<installation-id>' \
  github_app_private_key='<private-key-pem>'
```
