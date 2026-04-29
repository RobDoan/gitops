#!/usr/bin/env bash
# cloudflared-bootstrap.sh — one-time setup for the homelander Cloudflare Tunnel.
#
# Idempotent: safe to re-run.
# Required env (one of these paths must exist):
#   CF_API_TOKEN — Cloudflare API token with Zone:DNS:Edit on quybits.com.
#                  If absent, the DNS step is skipped and instructions are printed.
#
# Reads:  $HOME/.cloudflared/cert.pem (created via `cloudflared tunnel login`)
#         $HOME/.cloudflared/<UUID>.json (created via `cloudflared tunnel create`)
#         vault-init-homelander.json (root-token source, repo root)
# Writes: Vault path secret/cloudflared/tunnel-credentials (key: credentials.json)
# Prints: TUNNEL_UUID — the value to paste into infrastructure/cloudflared/configmap.yaml

set -euo pipefail

TUNNEL_NAME="homelander"
DNS_HOSTNAMES=(
  "n8n-home.quybits.com"
  "grafana-home.quybits.com"
  "qdrant-home.quybits.com"
  "minio-home.quybits.com"
  "royal-dispatch-home.quybits.com"
  "royal-dispatch-admin-home.quybits.com"
  "hi.quybits.com"
)
ZONE_NAME="quybits.com"
EXPECTED_CONTEXT="homelander"
VAULT_PATH="secret/cloudflared/tunnel-credentials"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VAULT_INIT_FILE="${SCRIPT_DIR}/vault-init-homelander.json"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight: kube context must be homelander ---
current_ctx="$(kubectl config current-context 2>/dev/null || true)"
if [[ "$current_ctx" != "$EXPECTED_CONTEXT" ]]; then
  err "kubectl current-context is '$current_ctx', expected '$EXPECTED_CONTEXT'. Run 'kubectx $EXPECTED_CONTEXT' and retry."
fi

# --- Preflight: cloudflared CLI ---
if ! command -v cloudflared >/dev/null 2>&1; then
  log "cloudflared CLI not found — installing via Homebrew"
  if ! command -v brew >/dev/null 2>&1; then
    err "Homebrew not installed. Install cloudflared manually: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
  fi
  brew install cloudflared
fi

# --- Preflight: jq (used to extract token + parse cloudflared output) ---
if ! command -v jq >/dev/null 2>&1; then
  err "jq is required. Install with: brew install jq"
fi

# --- Preflight: vault-init-homelander.json exists ---
if [[ ! -f "$VAULT_INIT_FILE" ]]; then
  err "$VAULT_INIT_FILE not found. Cannot read Vault root token."
fi

# --- Preflight: vault must be reachable and unsealed ---
if ! kubectl -n vault exec vault-0 -- vault status >/dev/null 2>&1; then
  err "Vault on vault-0 is sealed or unreachable. Run: ./scripts/vault-unseal.sh homelander"
fi

# --- Step 1: cloudflared tunnel login (if needed) ---
if [[ ! -f "$HOME/.cloudflared/cert.pem" ]]; then
  log "Authenticating to Cloudflare (browser will open)"
  cloudflared tunnel login
else
  log "Cloudflare cert.pem present — skipping login"
fi

# --- Step 2: Create tunnel if it doesn't exist ---
tunnel_json="$(cloudflared tunnel list --output json)"
match_count="$(printf '%s' "$tunnel_json" | jq --arg n "$TUNNEL_NAME" '[.[] | select(.name == $n)] | length')"
if [[ "$match_count" -gt 1 ]]; then
  err "Found $match_count tunnels named '$TUNNEL_NAME'. Delete duplicates in the Cloudflare dashboard, then retry."
fi
existing_uuid="$(printf '%s' "$tunnel_json" | jq -r --arg n "$TUNNEL_NAME" '.[] | select(.name == $n) | .id')"
if [[ -n "$existing_uuid" ]]; then
  log "Tunnel '$TUNNEL_NAME' already exists (UUID: $existing_uuid)"
  TUNNEL_UUID="$existing_uuid"
else
  log "Creating tunnel '$TUNNEL_NAME'"
  cloudflared tunnel create "$TUNNEL_NAME"
  TUNNEL_UUID="$(cloudflared tunnel list --output json | jq -r --arg n "$TUNNEL_NAME" '.[] | select(.name == $n) | .id')"
  if [[ -z "$TUNNEL_UUID" || "$TUNNEL_UUID" == "null" ]]; then
    err "Tunnel created but UUID could not be read"
  fi
fi

CRED_FILE="$HOME/.cloudflared/${TUNNEL_UUID}.json"
if [[ ! -f "$CRED_FILE" ]]; then
  err "Credentials file $CRED_FILE not found. Re-run after deleting the tunnel via the Cloudflare dashboard, or copy the file from wherever the tunnel was originally created."
fi

# --- Step 3: Per-host DNS CNAMEs via Cloudflare API (or print manual instructions) ---
TARGET="${TUNNEL_UUID}.cfargotunnel.com"
if [[ -n "${CF_API_TOKEN:-}" ]]; then
  zone_id="$(curl -fsSL -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" \
    | jq -r '.result[0].id')"
  if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
    err "Could not resolve zone ID for $ZONE_NAME. Check CF_API_TOKEN scope (Zone:Read on $ZONE_NAME)."
  fi

  for hostname in "${DNS_HOSTNAMES[@]}"; do
    log "Ensuring DNS record: $hostname CNAME $TARGET (proxied)"

    list_response="$(curl -fsSL -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME&name=${hostname}")"
    if [[ "$(printf '%s' "$list_response" | jq -r '.success')" != "true" ]]; then
      err "Cloudflare API list failed for $hostname: $(printf '%s' "$list_response" | jq -r '.errors[0].message // "unknown error"')"
    fi
    existing_record="$(printf '%s' "$list_response" | jq -r '.result[0]')"

    if [[ "$existing_record" != "null" ]]; then
      existing_target="$(echo "$existing_record" | jq -r '.content')"
      record_id="$(echo "$existing_record" | jq -r '.id')"
      if [[ "$existing_target" == "$TARGET" ]]; then
        log "  $hostname: already correct — skipping"
      else
        log "  $hostname: updating (was: $existing_target)"
        response="$(curl -fsSL -X PUT \
          -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
          "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
          -d "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${TARGET}\",\"proxied\":true}")"
        if [[ "$(printf '%s' "$response" | jq -r '.success')" != "true" ]]; then
          err "Cloudflare API DNS update failed for $hostname: $(printf '%s' "$response" | jq -r '.errors[0].message // "unknown error"')"
        fi
      fi
    else
      log "  $hostname: creating new record"
      response="$(curl -fsSL -X POST \
        -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
        -d "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${TARGET}\",\"proxied\":true}")"
      if [[ "$(printf '%s' "$response" | jq -r '.success')" != "true" ]]; then
        err "Cloudflare API DNS create failed for $hostname: $(printf '%s' "$response" | jq -r '.errors[0].message // "unknown error"')"
      fi
    fi
  done
else
  log "CF_API_TOKEN not set — skipping automated DNS"
  cat <<EOF

  >>> MANUAL STEP REQUIRED <<<
  In the Cloudflare dashboard for zone $ZONE_NAME, add the following DNS records (all CNAME, all Proxied/orange-cloud ON):

EOF
  for hostname in "${DNS_HOSTNAMES[@]}"; do
    printf "    %s  ->  %s\n" "$hostname" "$TARGET"
  done
  echo
fi

# --- Step 4: Store credentials.json in Vault ---
log "Storing credentials in Vault at $VAULT_PATH"
ROOT_TOKEN="$(jq -r '.root_token' "$VAULT_INIT_FILE")"
if [[ -z "$ROOT_TOKEN" || "$ROOT_TOKEN" == "null" ]]; then
  err "root_token not found in $VAULT_INIT_FILE"
fi

# `vault kv put` reads from stdin via @-, but kubectl exec doesn't pipe well.
# Workaround: copy the file into the pod, write from there, then delete.
TMP_NAME="cloudflared-creds-$(date +%s).json"
kubectl -n vault cp "$CRED_FILE" "vault-0:/tmp/${TMP_NAME}"
trap 'kubectl -n vault exec vault-0 -- rm -f "/tmp/'"${TMP_NAME}"'" >/dev/null 2>&1 || true' EXIT

kubectl -n vault exec -i vault-0 -- sh -c \
  'VAULT_TOKEN="$1" vault kv put "$2" "credentials.json=@$3" >/dev/null' \
  -- "$ROOT_TOKEN" "$VAULT_PATH" "/tmp/${TMP_NAME}"

kubectl -n vault exec vault-0 -- rm "/tmp/${TMP_NAME}"
trap - EXIT

# --- Step 5: Print the UUID for the user ---
cat <<EOF

==========================================================================
  Bootstrap complete.

  TUNNEL_UUID: $TUNNEL_UUID

  NEXT STEP (one-time, manual):
    1. Open infrastructure/cloudflared/configmap.yaml
    2. Replace the literal string:
         REPLACE_WITH_TUNNEL_UUID
       with:
         $TUNNEL_UUID
    3. Commit and push. Flux will reconcile within ~10 minutes
       (or run: flux reconcile kustomization cloudflared --with-source)

==========================================================================
EOF
