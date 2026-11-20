#!/usr/bin/env bash
# timescaledb-write-pwm-env.sh — phase 2: point the MacBook's PWM projects at homelander.
#
# For each env file: back up the real file once to <file>.pre-k8s, then set each key
# (replace the `KEY=` line, or append it). Writes through symlinks (PWM's .env links to .env.us).
# Passwords and the MinIO secret come from Vault. Values are never printed.
#
# One-time migration tooling. Spec: docs/superpowers/specs/2026-11-18-shared-timescaledb-design.md

set -euo pipefail

HOST=100.89.244.65
MINIO_URL="http://${HOST}:9000"
AI="$HOME/Projects/ai-agents"
EXPECTED_CONTEXT=homelander
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VAULT_INIT_FILE="${SCRIPT_DIR}/vault-init-homelander.json"

err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

current_ctx="$(kubectl config current-context 2>/dev/null || true)"
[[ "$current_ctx" == "$EXPECTED_CONTEXT" ]] || err "kubectl current-context is '$current_ctx', expected '$EXPECTED_CONTEXT'"
[[ -f "$VAULT_INIT_FILE" ]] || err "$VAULT_INIT_FILE not found"
ROOT_TOKEN="$(jq -r '.root_token' "$VAULT_INIT_FILE")"
[[ -n "$ROOT_TOKEN" && "$ROOT_TOKEN" != "null" ]] || err "root_token not found in $VAULT_INIT_FILE"

vault_field() {
  printf '%s\n' "$ROOT_TOKEN" | kubectl -n vault exec -i vault-0 -- sh -c \
    'read -r VAULT_TOKEN; export VAULT_TOKEN; vault kv get -field="$2" "$1"' _ "$1" "$2"
}

WEALTH_PW="$(vault_field secret/pwm/postgres wealth_password)"
READER_PW="$(vault_field secret/pwm/postgres reader_password)"
MINIO_SECRET="$(vault_field secret/pwm/minio secret_key)"
[[ -n "$WEALTH_PW" && -n "$READER_PW" && -n "$MINIO_SECRET" ]] || err "empty value in Vault pwm/postgres or pwm/minio"

US="postgresql://wealth:${WEALTH_PW}@${HOST}:5432/wealth_manager"
CA="postgresql://wealth:${WEALTH_PW}@${HOST}:5432/wealth_manager_ca"
R_US="postgresql://pwm_reader:${READER_PW}@${HOST}:5432/wealth_manager"
R_CA="postgresql://pwm_reader:${READER_PW}@${HOST}:5432/wealth_manager_ca"

# set_keys FILE KEY=VALUE... — the value travels in the environment, not on argv.
set_keys() {
  local file=$1 pair key tmp real; shift
  [[ -f "$file" ]] || err "$file not found"
  # Back up the real file once, so .env and the .env.us it links to share one backup.
  real="$(realpath "$file")"
  [[ -e "$real.pre-k8s" ]] || cp -p "$real" "$real.pre-k8s"
  for pair in "$@"; do
    key=${pair%%=*}
    tmp="$(mktemp)"
    K="$key" V="${pair#*=}" awk '
      BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; done = 0 }
      index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next }
      { print }
      END { if (!done) print k "=" v }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"   # keeps the inode, permissions and any symlink
    rm -f "$tmp"
    printf '%s: %s set\n' "$file" "$key"
  done
}

PWM="$AI/personal-wealth-manager"
set_keys "$PWM/.env" "DATABASE_URL=$US" "PWM_US_DATABASE_URL=$US" "PWM_CA_DATABASE_URL=$CA"
set_keys "$PWM/.env.us" "DATABASE_URL=$US"
set_keys "$PWM/.env.ca" "DATABASE_URL=$CA"

MINIO_KEYS=("PWMT_MINIO_ENDPOINT=$MINIO_URL" "PWMT_MINIO_ACCESS_KEY=pwm" "PWMT_MINIO_SECRET_KEY=$MINIO_SECRET")
set_keys "$AI/pwm-technical/.env.us" "PWMT_DB_URL=$US" "${MINIO_KEYS[@]}"
set_keys "$AI/pwm-technical/.env.ca" "PWMT_DB_URL=$CA" "${MINIO_KEYS[@]}"

# Keeps today's behaviour: pwm-technical's built-in default is the US database.
set_keys "$AI/pwm-momentum/.env" "PWMT_DB_URL=$US"

set_keys "$AI/pwm-core/.env" "PWM_READER_URL_US=$R_US" "PWM_READER_URL_CA=$R_CA"

echo "Done. Backups: <file>.pre-k8s (they hold the old values; delete on/after 2026-12-18)."
