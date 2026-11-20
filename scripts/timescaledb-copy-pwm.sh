#!/usr/bin/env bash
# timescaledb-copy-pwm.sh [db...] — phase 2: copy PWM's prod databases from the MacBook
# (pwm-postgres-1, PG 16, TimescaleDB 2.27.2) into timescaledb-0 (PG 18, TimescaleDB 2.32.0),
# then mirror PWM's MinIO buckets into the cluster MinIO.
#
# Default dbs: wealth_manager wealth_manager_ca. Pass names to redo only some of them, after
# dropping a half-restored one by hand. The source is only read.
#
# Order per database (TimescaleDB's documented restore path):
#   CREATE DATABASE … TEMPLATE template0   (template1 already carries timescaledb 2.32.0)
#   CREATE EXTENSION timescaledb VERSION '2.27.2'; SELECT timescaledb_pre_restore();
#   pg_restore; SELECT timescaledb_post_restore();
#   new session: ALTER EXTENSION timescaledb UPDATE; ANALYZE
#
# Keeps ~/timescaledb-migration/<db>.dump as a local safety copy. Log: phase2-<UTC ts>.log
# Passwords come from Vault and are never printed.
#
# One-time migration tooling. Spec: docs/superpowers/specs/2026-11-18-shared-timescaledb-design.md

set -euo pipefail

NS=postgres
NEW=timescaledb-0
SRC=pwm-postgres-1
SRC_MINIO=pwm-minio-1
DST_MINIO_URL=http://100.89.244.65:9000
BUCKETS=(pwm-technical-artifacts pwm-technical-artifacts-ca)
DBS=(wealth_manager wealth_manager_ca)
[[ $# -gt 0 ]] && DBS=("$@")
TS_FROM=2.27.2
TS_TO=2.32.0
EXPECTED_CONTEXT=homelander
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VAULT_INIT_FILE="${SCRIPT_DIR}/vault-init-homelander.json"
LOG_DIR="$HOME/timescaledb-migration"
LOG="$LOG_DIR/phase2-$(date -u +%Y%m%dT%H%M%SZ).log"

mkdir -p "$LOG_DIR"
: > "$LOG"
log() { printf '\033[1;34m==>\033[0m %s\n' "$*" | tee -a "$LOG"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

# --- Preflight: nothing may write to the source while it is copied ---
current_ctx="$(kubectl config current-context 2>/dev/null || true)"
[[ "$current_ctx" == "$EXPECTED_CONTEXT" ]] || err "kubectl current-context is '$current_ctx', expected '$EXPECTED_CONTEXT'"

active_cron="$(crontab -l 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -E 'cron_materialize|pwm-technical|pwm-momentum' || true)"
[[ -z "$active_cron" ]] || err "cron still has active PWM jobs; pause them first (plan Task 11 step 1):
$active_cron"

# pwm-core-postgres is pwm-core's own database (out of scope), and *-test-* are test databases.
running="$(docker ps --format '{{.Names}}' | grep '^pwm-' \
  | grep -vE "^(${SRC}|${SRC_MINIO}|pwm-core-postgres)\$" | grep -v -- '-test-' || true)"
[[ -z "$running" ]] || err "stop these containers first: $(echo "$running" | tr '\n' ' ')"

kubectl -n "$NS" wait --for=condition=Ready "pod/$NEW" --timeout=30s >/dev/null || err "$NEW is not Ready"
[[ -f "$VAULT_INIT_FILE" ]] || err "$VAULT_INIT_FILE not found"
ROOT_TOKEN="$(jq -r '.root_token' "$VAULT_INIT_FILE")"
[[ -n "$ROOT_TOKEN" && "$ROOT_TOKEN" != "null" ]] || err "root_token not found in $VAULT_INIT_FILE"

vault_field() {
  printf '%s\n' "$ROOT_TOKEN" | kubectl -n vault exec -i vault-0 -- sh -c \
    'read -r VAULT_TOKEN; export VAULT_TOKEN; vault kv get -field="$2" "$1"' _ "$1" "$2"
}
new_psql() { kubectl -n "$NS" exec -i "$NEW" -- psql -X -q -v ON_ERROR_STOP=1 -U postgres "$@"; }
src_psql() { docker exec -i "$SRC" psql -X -q -v ON_ERROR_STOP=1 -U wealth "$@"; }

# --- Roles (once; passwords re-synced from Vault on every run) ---
WEALTH_PW="$(vault_field secret/pwm/postgres wealth_password)"
READER_PW="$(vault_field secret/pwm/postgres reader_password)"
[[ -n "$WEALTH_PW" && -n "$READER_PW" ]] || err "empty password at secret/pwm/postgres"

log "Roles wealth (NOSUPERUSER) and pwm_reader (read-only) on $NEW"
new_psql -d postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'wealth') THEN CREATE ROLE wealth LOGIN NOSUPERUSER; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pwm_reader') THEN CREATE ROLE pwm_reader LOGIN; END IF;
END \$\$;
ALTER ROLE wealth WITH LOGIN NOSUPERUSER PASSWORD '${WEALTH_PW}';
ALTER ROLE pwm_reader WITH LOGIN NOSUPERUSER PASSWORD '${READER_PW}';
GRANT pg_read_all_data TO pwm_reader;
ALTER ROLE pwm_reader SET default_transaction_read_only = on;
SQL

# Reported from both sides and diffed, beyond the per-table row counts.
PARITY_SQL="SET TimeZone = 'UTC';
SELECT 'hypertable ' || hypertable_schema || '.' || hypertable_name || ' chunks=' || num_chunks
  FROM timescaledb_information.hypertables
UNION ALL
SELECT 'ohlcv_daily max(ts)=' || coalesce(max(ts)::text, 'null') FROM ohlcv_daily;"

# Prints unexpected pg_restore errors, each with the statement that caused it. Allowed:
# the timescaledb extension already existing (we pre-create it) and its COMMENT.
unexpected_restore_errors() {
  awk '
    /^pg_restore: error:/ { if (pending != "") print pending; pending = $0; next }
    /^Command was: / {
      if (pending != "") {
        if ($0 !~ /^Command was: (CREATE EXTENSION (IF NOT EXISTS )?timescaledb|COMMENT ON EXTENSION timescaledb)/ \
            && pending !~ /extension "timescaledb" already exists/)
          print pending " | " $0
        pending = ""
      }
      next
    }
    END { if (pending != "") print pending }
  ' "$1"
}

for db in "${DBS[@]}"; do
  if [[ -n "$(new_psql -d postgres -At -c "SELECT 1 FROM pg_database WHERE datname = '$db'")" ]]; then
    err "$db already exists on $NEW; refusing to overwrite. Drop it by hand, then re-run with: $0 $db"
  fi

  log "[$db] create database, timescaledb $TS_FROM, pre_restore"
  new_psql -d postgres -c "CREATE DATABASE $db OWNER wealth TEMPLATE template0"
  new_psql -d "$db" -c "CREATE EXTENSION timescaledb VERSION '$TS_FROM'" -c "SELECT timescaledb_pre_restore()" >/dev/null

  log "[$db] dump from $SRC -> $LOG_DIR/$db.dump"
  docker exec "$SRC" pg_dump -U wealth -Fc -d "$db" > "$LOG_DIR/$db.dump" 2>>"$LOG"
  log "[$db] dump size $(du -h "$LOG_DIR/$db.dump" | cut -f1)"

  log "[$db] restore into $NEW (several minutes for wealth_manager)"
  restore_log="$LOG_DIR/$db.restore.log"
  set +e
  kubectl -n "$NS" exec -i "$NEW" -- pg_restore -U postgres -d "$db" < "$LOG_DIR/$db.dump" > "$restore_log" 2>&1
  rc=$?
  set -e
  cat "$restore_log" >> "$LOG"
  if [[ $rc -ne 0 ]] && ! grep -q 'errors ignored on restore' "$restore_log"; then
    err "[$db] restore did not finish (exit $rc); see $restore_log"
  fi
  unexpected="$(unexpected_restore_errors "$restore_log")"
  [[ -z "$unexpected" ]] || err "[$db] unexpected restore errors:
$unexpected"

  log "[$db] post_restore, then update the extension in a fresh session"
  new_psql -d "$db" -c "SELECT timescaledb_post_restore()" >/dev/null
  new_psql -d "$db" -c "ALTER EXTENSION timescaledb UPDATE"
  new_psql -d "$db" -c "ANALYZE"
  ver="$(new_psql -d "$db" -At -c "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")"
  log "[$db] extversion $ver"
  [[ "$ver" == "$TS_TO" ]] || err "[$db] expected timescaledb $TS_TO, got '$ver'"

  log "[$db] hypertable and max(ts) parity"
  if ! diff <(src_psql -d "$db" -At -c "$PARITY_SQL" | LC_ALL=C sort) \
            <(new_psql -d "$db" -At -c "$PARITY_SQL" | LC_ALL=C sort) | tee -a "$LOG"; then
    err "[$db] hypertables or max(ts) differ (diff above)"
  fi
  log "[$db] OK"
done

# --- MinIO: mirror PWM's buckets with the dedicated pwm key ---
MINIO_KEY="$(vault_field secret/pwm/minio access_key)"
MINIO_SECRET="$(vault_field secret/pwm/minio secret_key)"
[[ -n "$MINIO_KEY" && -n "$MINIO_SECRET" ]] || err "empty key at secret/pwm/minio"

log "MinIO: mirror ${BUCKETS[*]} -> $DST_MINIO_URL"
printf '%s\n%s\n' "$MINIO_KEY" "$MINIO_SECRET" | docker exec -i "$SRC_MINIO" sh -c '
  set -e
  IFS= read -r k; IFS= read -r s
  dst_url=$1; shift
  mc alias set src http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc alias set dst "$dst_url" "$k" "$s" >/dev/null
  trap "mc alias remove dst >/dev/null 2>&1 || true" EXIT
  for b in "$@"; do
    mc mirror --preserve --quiet "src/$b" "dst/$b"
    echo "src: $(mc du "src/$b")"
    echo "dst: $(mc du "dst/$b")"
  done' _ "$DST_MINIO_URL" "${BUCKETS[@]}" 2>&1 | tee -a "$LOG"

log "Done. Log: $LOG"
log "Next: row-count parity (plan Task 11 step 2)."
