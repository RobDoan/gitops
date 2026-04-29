#!/bin/bash
set -e

usage() {
  echo "Usage: $0 <cluster> [--bootstrap]"
  echo ""
  echo "Clusters:"
  echo "  rackspace    - Use vault-init.json"
  echo "  homelander   - Use vault-init-homelander.json"
  echo ""
  echo "Options:"
  echo "  --bootstrap  After unsealing, create the vault-root-token secret"
  echo "               and restart the vault-bootstrap job"
  echo ""
  echo "Examples:"
  echo "  $0 rackspace"
  echo "  $0 homelander --bootstrap"
  exit 1
}

CLUSTER="${1:-}"
BOOTSTRAP=false

if [[ -z "$CLUSTER" ]]; then
  usage
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap) BOOTSTRAP=true; shift ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Resolve init file based on cluster
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
case "$CLUSTER" in
  rackspace)
    INIT_FILE="${SCRIPT_DIR}/vault-init.json"
    ;;
  homelander)
    INIT_FILE="${SCRIPT_DIR}/vault-init-homelander.json"
    ;;
  *)
    echo "Error: Unknown cluster '$CLUSTER'. Must be 'rackspace' or 'homelander'."
    exit 1
    ;;
esac

if [[ ! -f "$INIT_FILE" ]]; then
  echo "Error: $INIT_FILE not found"
  exit 1
fi

echo "==> Cluster: $CLUSTER"
echo "==> Init file: $INIT_FILE"

# --- Unseal ---
KEYS=$(jq -r '.unseal_keys_b64[]' "$INIT_FILE")
TOTAL=$(echo "$KEYS" | wc -l | tr -d ' ')
THRESHOLD=$(jq -r '.unseal_threshold // 2' "$INIT_FILE")

# Pick $THRESHOLD random unique indices (1-based)
INDICES=($(shuf -i 1-$TOTAL -n $THRESHOLD))

echo ""
echo "==> Unsealing Vault using $THRESHOLD of $TOTAL keys (keys: ${INDICES[*]})..."

for i in "${INDICES[@]}"; do
  KEY=$(echo "$KEYS" | sed -n "${i}p")
  echo "  Applying key $i..."
  kubectl exec -n vault vault-0 -- vault operator unseal "$KEY"
done

echo ""
echo "==> Vault status:"
kubectl exec -n vault vault-0 -- vault status

# --- Bootstrap (optional) ---
if [[ "$BOOTSTRAP" == true ]]; then
  ROOT_TOKEN=$(jq -r '.root_token' "$INIT_FILE")

  echo ""
  echo "==> Creating vault-root-token secret..."
  kubectl create secret generic vault-root-token \
    -n vault \
    --from-literal=token="${ROOT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo ""
  echo "==> Deleting old bootstrap job (if any)..."
  kubectl delete job vault-bootstrap -n vault --ignore-not-found

  echo ""
  echo "==> Restarting bootstrap job via Flux..."
  flux reconcile kustomization vault

  echo ""
  echo "==> Waiting for bootstrap job to complete..."
  kubectl wait --for=condition=complete job/vault-bootstrap -n vault --timeout=120s 2>/dev/null \
    || echo "Warning: bootstrap job did not complete within 120s. Check with: kubectl logs -n vault job/vault-bootstrap"

  echo ""
  echo "==> Bootstrap done. Remember to update placeholder secrets in Vault!"
  echo "    vault kv put secret/grafana admin_password=<real-password> admin_user=admin"
  echo "    vault kv put secret/qdrant api_key=<real-key>"
  echo "    vault kv put secret/n8n encryption_key=<real-key>"
fi
