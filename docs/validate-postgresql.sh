#!/usr/bin/env bash
# Validate PostgreSQL init-job results
# Usage: ./docs/validate-postgresql.sh [namespace] [pod]
# Defaults: namespace=utility, pod=postgres-0
set -uo pipefail

NS="${1:-utility}"
POD="${2:-postgres-0}"
PASS=0
FAIL=0

# ─── Configuration ───────────────────────────────────────────────
# db:owner:secret-key
DATABASES=(
  "auth:auth_user:auth-user-password"
  "dataops:dataops_user:dataops-user-password"
  "metadata:metadata_user:metadata-user-password"
  "project:project_user:project-user-password"
)

# db:schema1,schema2,...:user
SCHEMAS=(
  "metadata:metadata:metadata_user"
  "auth:pilot_casbin,pilot_event,pilot_invitation,pilot_ldap:auth_user"
)

# db:extension1,extension2,...
EXTENSIONS=(
  "metadata:ltree,pg_cron"
)

# db:jobname1,jobname2,...
CRON_JOBS=(
  "metadata:expire_REGISTERED_items,expire_job_history"
)
# ─────────────────────────────────────────────────────────────────

run_sql() {
  local db="${1}" query="${2}"
  kubectl exec -i -n "$NS" "$POD" -- bash -c \
    'PGPASSWORD=$POSTGRES_PASSWORD psql -U postgres -d '"${db}"' -t -A' <<< "$query" 2>/dev/null || true
}

check() {
  local desc="$1" result="$2" expected="$3"
  if [[ "$result" == *"$expected"* ]]; then
    echo "  ✅ $desc"
    ((PASS++))
  else
    echo "  ❌ $desc (expected: $expected, got: $result)"
    ((FAIL++))
  fi
}

echo "=== PostgreSQL Validation ==="
echo "Namespace: $NS | Pod: $POD"
echo ""

# --- Pod health ---
echo "▸ Pod status"
pod_status=$(kubectl get pod -n "$NS" "$POD" -o jsonpath='{.status.phase}')
check "Pod running" "$pod_status" "Running"

# --- Databases & ownership ---
echo ""
echo "▸ Databases & ownership"
dbs=$(run_sql postgres "SELECT datname FROM pg_database ORDER BY datname")
users=$(run_sql postgres "SELECT usename FROM pg_user ORDER BY usename")
for entry in "${DATABASES[@]}"; do
  IFS=: read -r db owner _ <<< "$entry"
  check "Database '$db' exists" "$dbs" "$db"
  actual=$(run_sql postgres "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='${db}'")
  check "DB '$db' owned by $owner" "$actual" "$owner"
  check "User '$owner' exists" "$users" "$owner"
done

# --- Schemas & privileges ---
echo ""
echo "▸ Schemas & privileges"
for entry in "${SCHEMAS[@]}"; do
  IFS=: read -r db schema_csv user <<< "$entry"
  IFS=, read -ra schema_list <<< "$schema_csv"
  for s in "${schema_list[@]}"; do
    exists=$(run_sql "$db" "SELECT 1 FROM pg_namespace WHERE nspname='${s}'")
    check "[$db] Schema '$s' exists" "$exists" "1"
    u=$(run_sql "$db" "SELECT has_schema_privilege('${user}', '${s}', 'USAGE')")
    c=$(run_sql "$db" "SELECT has_schema_privilege('${user}', '${s}', 'CREATE')")
    check "[$db] $user USAGE on $s" "$u" "t"
    check "[$db] $user CREATE on $s" "$c" "t"
  done
done

# --- Extensions ---
echo ""
echo "▸ Extensions"
for entry in "${EXTENSIONS[@]}"; do
  IFS=: read -r db ext_csv <<< "$entry"
  extensions=$(run_sql "$db" "SELECT extname FROM pg_extension ORDER BY extname")
  IFS=, read -ra ext_list <<< "$ext_csv"
  for ext in "${ext_list[@]}"; do
    check "[$db] Extension '$ext'" "$extensions" "$ext"
  done
done

# --- Cron jobs ---
echo ""
echo "▸ Cron jobs"
for entry in "${CRON_JOBS[@]}"; do
  IFS=: read -r db job_csv <<< "$entry"
  jobs=$(run_sql "$db" "SELECT jobname FROM cron.job ORDER BY jobname")
  IFS=, read -ra job_list <<< "$job_csv"
  for job in "${job_list[@]}"; do
    check "[$db] Cron '$job'" "$jobs" "$job"
  done
done

# --- User connectivity ---
echo ""
echo "▸ User connectivity"
for entry in "${DATABASES[@]}"; do
  IFS=: read -r db owner secret_key <<< "$entry"
  pwd=$(kubectl get secret -n "$NS" postgresql-credentials -o jsonpath="{.data.${secret_key}}" | base64 -d)
  result=$(printf '%s\n' "$pwd" | kubectl exec -i -n "$NS" "$POD" -- \
    sh -c 'read -r pw; PGPASSWORD="$pw" psql -U "$1" -d "$2" -t -A -c "SELECT 1"' _ "$owner" "$db" 2>&1) || true
  unset pwd
  check "$owner can connect to $db" "$result" "1"
done

# --- Summary ---
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "⚠️  Some checks failed!"
  exit 1
else
  echo "All checks passed."
fi
