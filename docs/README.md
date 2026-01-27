# Docs

Operational scripts and runbooks for the HDC platform.

## Scripts

| Script | Description | Usage |
|--------|-------------|-------|
| [validate-postgresql.sh](validate-postgresql.sh) | Validates PostgreSQL init-job results: databases, ownership, users, schemas, extensions, cron jobs, privileges, and connectivity | `./docs/validate-postgresql.sh [namespace] [pod]` |
