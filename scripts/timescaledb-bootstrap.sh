#!/usr/bin/env bash
# timescaledb-bootstrap.sh — one-time prerequisites for the shared TimescaleDB on homelander.
#
# Idempotent: safe to re-run. A Vault path that already exists is kept as-is.
#
# Required env (only when secret/postgres-backup does not exist yet):
#   AWS_BACKUP_KEY_ID, AWS_BACKUP_SECRET — access key of IAM user homelander-pg-backup
#   AWS_BACKUP_BUCKET                    — the off-box S3 bucket (ca-central-1)
#
# Reads:  vault-init-homelander.json (root-token source, repo root)
# Writes: Vault secret/postgres-backup, secret/pwm/postgres, secret/pwm/minio
#         MinIO buckets postgres-backups, pwm-technical-artifacts, pwm-technical-artifacts-ca
#         MinIO policies postgres-backup-rw, pwm-rw; users postgres-backup, pwm
#
# Secrets travel to the pods on stdin, never on this machine's command line, and are
# never printed. Run it in your own terminal (see the plan, Task 2 step 4).
#
# Spec: docs/superpowers/specs/2026-11-18-shared-timescaledb-design.md

set -euo pipefail

EXPECTED_CONTEXT="homelander"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VAULT_INIT_FILE="${SCRIPT_DIR}/vault-init-homelander.json"
AWS_REGION="ca-central-1"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight ---
current_ctx="$(kubectl config current-context 2>/dev/null || true)"
[[ "$current_ctx" == "$EXPECTED_CONTEXT" ]] || err "kubectl current-context is '$current_ctx', expected '$EXPECTED_CONTEXT'. Run: kubectx $EXPECTED_CONTEXT"
command -v jq >/dev/null 2>&1 || err "jq is required. Install with: brew install jq"
command -v openssl >/dev/null 2>&1 || err "openssl is required"
[[ -f "$VAULT_INIT_FILE" ]] || err "$VAULT_INIT_FILE not found. Cannot read Vault root token."
kubectl -n vault exec vault-0 -- vault status >/dev/null 2>&1 || err "Vault on vault-0 is sealed or unreachable. Run: ./scripts/vault-unseal.sh homelander"

ROOT_TOKEN="$(jq -r '.root_token' "$VAULT_INIT_FILE")"
[[ -n "$ROOT_TOKEN" && "$ROOT_TOKEN" != "null" ]] || err "root_token not found in $VAULT_INIT_FILE"

gen_password() { openssl rand -base64 36 | tr -d '/+=' | cut -c1-40; }

# --- Vault helpers: the token is always the first stdin line ---
vault_has() {
  printf '%s\n' "$ROOT_TOKEN" | kubectl -n vault exec -i vault-0 -- sh -c \
    'read -r VAULT_TOKEN; export VAULT_TOKEN; vault kv get "$1" >/dev/null 2>&1' _ "$1"
}

vault_field() {
  printf '%s\n' "$ROOT_TOKEN" | kubectl -n vault exec -i vault-0 -- sh -c \
    'read -r VAULT_TOKEN; export VAULT_TOKEN; vault kv get -field="$2" "$1"' _ "$1" "$2"
}

# vault_put PATH KEY...  — one value per KEY on stdin, after the token line.
vault_put() {
  kubectl -n vault exec -i vault-0 -- sh -c '
    read -r VAULT_TOKEN; export VAULT_TOKEN
    p=$1; shift; n=$#
    for k in "$@"; do IFS= read -r v; set -- "$@" "$k=$v"; done
    shift "$n"
    vault kv put "$p" "$@" >/dev/null' _ "$@"
}

# --- Vault: secret/postgres-backup ---
if vault_has secret/postgres-backup; then
  log "kept     vault secret/postgres-backup"
else
  [[ -n "${AWS_BACKUP_KEY_ID:-}" ]] || err "AWS_BACKUP_KEY_ID is empty (IAM user homelander-pg-backup access key id)"
  [[ -n "${AWS_BACKUP_SECRET:-}" ]] || err "AWS_BACKUP_SECRET is empty (IAM user homelander-pg-backup secret)"
  [[ -n "${AWS_BACKUP_BUCKET:-}" ]] || err "AWS_BACKUP_BUCKET is empty (the S3 bucket name)"
  {
    printf '%s\n' "$ROOT_TOKEN" "postgres-backup" "$(gen_password)" \
      "$AWS_BACKUP_KEY_ID" "$AWS_BACKUP_SECRET" "$AWS_BACKUP_BUCKET" "$AWS_REGION"
  } | vault_put secret/postgres-backup minio_access_key minio_secret_key \
        aws_access_key_id aws_secret_access_key aws_bucket aws_region
  log "created  vault secret/postgres-backup"
fi

# --- Vault: secret/pwm/postgres ---
if vault_has secret/pwm/postgres; then
  log "kept     vault secret/pwm/postgres"
else
  printf '%s\n' "$ROOT_TOKEN" "$(gen_password)" "$(gen_password)" \
    | vault_put secret/pwm/postgres wealth_password reader_password
  log "created  vault secret/pwm/postgres"
fi

# --- Vault: secret/pwm/minio ---
if vault_has secret/pwm/minio; then
  log "kept     vault secret/pwm/minio"
else
  printf '%s\n' "$ROOT_TOKEN" "pwm" "$(gen_password)" \
    | vault_put secret/pwm/minio access_key secret_key
  log "created  vault secret/pwm/minio"
fi

# --- MinIO helpers: every call sets the root alias from the pod's own env first ---
minio_sh() {
  kubectl -n minio exec -i deploy/minio -- sh -c \
    'mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null || exit 1
     '"$1" _ "${@:2}"
}

ensure_bucket() {
  if minio_sh 'mc ls "local/$1" >/dev/null 2>&1' "$1" </dev/null; then
    log "kept     minio bucket $1"
  else
    minio_sh 'mc mb --ignore-existing "local/$1" >/dev/null' "$1" </dev/null
    log "created  minio bucket $1"
  fi
}

# ensure_policy NAME BUCKET... — List on each bucket, Get/Put/Delete on its objects.
ensure_policy() {
  local name=$1; shift
  local buckets objects b
  buckets="$(for b in "$@"; do printf '"arn:aws:s3:::%s",' "$b"; done)"
  objects="$(for b in "$@"; do printf '"arn:aws:s3:::%s/*",' "$b"; done)"
  printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket"],"Resource":[%s]},{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":[%s]}]}\n' \
    "${buckets%,}" "${objects%,}" \
    | minio_sh 'cat > "/tmp/$1.json" && mc admin policy create local "$1" "/tmp/$1.json" >/dev/null; rc=$?; rm -f "/tmp/$1.json"; exit $rc' "$name"
  log "created  minio policy $name (create-or-update)"
}

# ensure_user NAME POLICY VAULT_PATH VAULT_FIELD — the secret is read from Vault, sent on stdin.
ensure_user() {
  local name=$1 policy=$2 secret existed=no
  secret="$(vault_field "$3" "$4")"
  [[ -n "$secret" ]] || err "empty $4 at $3"
  if minio_sh 'mc admin user info local "$1" >/dev/null 2>&1' "$name" </dev/null; then existed=yes; fi
  printf '%s\n' "$secret" | minio_sh '
    IFS= read -r s
    mc admin user add local "$1" "$s" >/dev/null || exit 1
    out=$(mc admin policy attach local "$2" --user "$1" 2>&1) || case "$out" in
      *"already in effect"*|*"already attached"*) ;;
      *) echo "$out" >&2; exit 1 ;;
    esac' "$name" "$policy"
  if [[ "$existed" == yes ]]; then
    log "kept     minio user $name (secret re-synced from Vault, policy $policy)"
  else
    log "created  minio user $name (policy $policy)"
  fi
}

for b in postgres-backups pwm-technical-artifacts pwm-technical-artifacts-ca; do ensure_bucket "$b"; done
ensure_policy postgres-backup-rw postgres-backups
ensure_policy pwm-rw pwm-technical-artifacts pwm-technical-artifacts-ca
ensure_user postgres-backup postgres-backup-rw secret/postgres-backup minio_secret_key
ensure_user pwm pwm-rw secret/pwm/minio secret_key

log "Done. Next: the plan, Task 2 step 5 (agent verifies the MinIO users and buckets)."
