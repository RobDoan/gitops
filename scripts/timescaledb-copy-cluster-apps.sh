#!/usr/bin/env bash
# timescaledb-copy-cluster-apps.sh — phase 1: copy every database and role from the Bitnami
# server (postgres-postgresql-0) into timescaledb-0, PG 18 to PG 18.
#
# Run it after the writers are scaled to 0 (plan Task 7 step 1). The old server is only read.
# Log: ~/timescaledb-migration/phase1-<UTC timestamp>.log
# Exit 1 if the restore logged any ERROR other than `role "postgres" already exists`.
#
# One-time migration tooling. Spec: docs/superpowers/specs/2026-11-18-shared-timescaledb-design.md

set -euo pipefail

NS=postgres
OLD=postgres-postgresql-0
NEW=timescaledb-0
EXPECTED_CONTEXT=homelander
LOG_DIR="$HOME/timescaledb-migration"
LOG="$LOG_DIR/phase1-$(date -u +%Y%m%dT%H%M%SZ).log"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" | tee -a "$LOG"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

mkdir -p "$LOG_DIR"
: > "$LOG"

current_ctx="$(kubectl config current-context 2>/dev/null || true)"
[[ "$current_ctx" == "$EXPECTED_CONTEXT" ]] || err "kubectl current-context is '$current_ctx', expected '$EXPECTED_CONTEXT'"
kubectl -n "$NS" wait --for=condition=Ready "pod/$OLD" "pod/$NEW" --timeout=30s >/dev/null \
  || err "$OLD and $NEW must both be Ready"

# The Bitnami pod needs the superuser password even on 127.0.0.1.
OLD_PW='PGPASSWORD=$(cat /opt/bitnami/postgresql/secrets/postgres-password 2>/dev/null || printf %s "$POSTGRES_POSTGRES_PASSWORD"); export PGPASSWORD'
LOCALES="select datname, datcollate, datctype, datlocprovider from pg_database order by 1"

log "Locales on $OLD (old) — compare with the new server below"
kubectl -n "$NS" exec "$OLD" -- sh -c "$OLD_PW; psql -X -h 127.0.0.1 -U postgres -d postgres -c \"$LOCALES\"" 2>&1 | tee -a "$LOG"
log "Locales on $NEW (new, before the copy)"
kubectl -n "$NS" exec "$NEW" -- psql -X -U postgres -d postgres -c "$LOCALES" 2>&1 | tee -a "$LOG"

log "Copying all databases and roles: $OLD -> $NEW (this can take a few minutes)"
if ! kubectl -n "$NS" exec "$OLD" -- sh -c "$OLD_PW; pg_dumpall -U postgres -h 127.0.0.1" 2>>"$LOG" \
  | kubectl -n "$NS" exec -i "$NEW" -- psql -X -q -U postgres -d postgres -v ON_ERROR_STOP=0 >>"$LOG" 2>&1; then
  err "the copy pipeline failed; see $LOG"
fi

log "Locales on $NEW (new, after the copy)"
kubectl -n "$NS" exec "$NEW" -- psql -X -U postgres -d postgres -c "$LOCALES" 2>&1 | tee -a "$LOG"

unexpected="$(grep 'ERROR' "$LOG" | grep -v 'role "postgres" already exists' || true)"
if [[ -n "$unexpected" ]]; then
  printf '%s\n' "$unexpected" >&2
  err "unexpected errors during the restore (above). The old server is untouched. Log: $LOG"
fi

log "Done. No unexpected errors. Log: $LOG"
log "Next: compare row counts per database (plan Task 7 step 3)."
