#!/usr/bin/env bash
# personal-site-bootstrap.sh — one-time deploy prerequisites.
#
# Creates the Postgres role + database, generates a random app-user password
# + IP-hash salt, and writes both Vault paths (secret/personal-site/api and
# secret/personal-site/postgres) so the ExternalSecrets can reconcile.
#
# Idempotent where possible: Postgres role creation skips if it exists; Vault
# kv put overwrites by design (ESO picks up on next refresh, 1h).
#
# Required env (prompts if unset):
#   OPENAI_API_KEY     — paste from platform.openai.com
#   TURNSTILE_SECRET   — from Cloudflare dashboard → Turnstile → site → secret
#                        (use 1x0000000000000000000000000000000AA for dev testing)
#
# Preflight:
#   kubectx homelander
#   vault status (must be reachable + unsealed)
#   Postgres must be running at postgres-postgresql.postgres.svc

set -euo pipefail

EXPECTED_CONTEXT="homelander"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VAULT_INIT_FILE="${SCRIPT_DIR}/vault-init-homelander.json"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── Preflight ───────────────────────────────────────────────────────────────
current_ctx="$(kubectl config current-context 2>/dev/null || true)"
[[ "$current_ctx" == "$EXPECTED_CONTEXT" ]] || err "kubectx is '$current_ctx', expected '$EXPECTED_CONTEXT'. Run: kubectx $EXPECTED_CONTEXT"
# command -v vault >/dev/null || err "vault CLI not installed (brew install vault)"
# command -v jq    >/dev/null || err "jq not installed (brew install jq)"
# [[ -f "$VAULT_INIT_FILE" ]] || err "$VAULT_INIT_FILE not found"

export VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
export VAULT_TOKEN="$(jq -r .root_token "$VAULT_INIT_FILE")"

log "Checking Vault reachability at $VAULT_ADDR"
vault status >/dev/null || err "vault not reachable. Port-forward first: kubectl -n vault port-forward svc/vault 8200:8200"

# ── Inputs ──────────────────────────────────────────────────────────────────
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  read -rsp "OpenAI API key (sk-...): " OPENAI_API_KEY; echo
fi
[[ -n "$OPENAI_API_KEY" ]] || err "OPENAI_API_KEY is empty"

if [[ -z "${TURNSTILE_SECRET:-}" ]]; then
  read -rsp "Turnstile secret (or '1x0000000000000000000000000000000AA' for dev): " TURNSTILE_SECRET; echo
fi
[[ -n "$TURNSTILE_SECRET" ]] || err "TURNSTILE_SECRET is empty"

# ── Postgres role + DB ──────────────────────────────────────────────────────
log "Fetching Postgres admin password"
PG_ADMIN_PW="$(kubectl -n postgres get secret postgres-secrets -o jsonpath='{.data.postgres-password}' | base64 -d)"
[[ -n "$PG_ADMIN_PW" ]] || err "couldn't read postgres-secrets"

APP_PW="$(openssl rand -base64 24 | tr -d '+/=' | head -c 32)"
log "Creating role + database (idempotent)"
# Heredoc is quoted ('SQL') so local shell doesn't expand anything inside it.
# Inject APP_PW explicitly via psql -v so we don't string-interpolate a password
# into SQL (no escaping traps) and don't tangle with kubectl+bash+psql layers.
kubectl -n postgres exec -i postgres-postgresql-0 -- \
  env PGPASSWORD="$PG_ADMIN_PW" psql -U postgres \
  -v ON_ERROR_STOP=1 \
  -v app_pw="$APP_PW" <<'SQL'
SELECT 'CREATE ROLE personal_site LOGIN'
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='personal_site')\gexec
ALTER ROLE personal_site WITH PASSWORD :'app_pw';
SELECT 'CREATE DATABASE personal_site OWNER personal_site'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='personal_site')\gexec
GRANT ALL PRIVILEGES ON DATABASE personal_site TO personal_site;
SQL

PG_HOST="postgres-postgresql.postgres.svc.cluster.local"
PG_DSN="postgres://personal_site:${APP_PW}@${PG_HOST}:5432/personal_site"

# ── Generate IP hash salt ───────────────────────────────────────────────────
IP_HASH_SALT="$(openssl rand -hex 32)"

# ── Write Vault secrets ─────────────────────────────────────────────────────
log "Writing secret/personal-site/api"
vault kv put secret/personal-site/api \
  openai-api-key="$OPENAI_API_KEY" \
  qdrant-api-key="" \
  turnstile-secret="$TURNSTILE_SECRET" \
  ip-hash-salt="$IP_HASH_SALT" >/dev/null

log "Writing secret/personal-site/postgres"
vault kv put secret/personal-site/postgres \
  username="personal_site" \
  password="$APP_PW" \
  dsn="$PG_DSN" >/dev/null

log "Done. Verify:"
echo "  vault kv get secret/personal-site/api"
echo "  vault kv get secret/personal-site/postgres"
echo
echo "Next: merge feat/personal-site to main, wait for Flux, then watch the pod:"
echo "  kubectl -n personal-site get pods -w"
