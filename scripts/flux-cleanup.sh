#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

confirm() {
  read -r -p "$(echo -e "${YELLOW}$1 [y/N]:${NC} ")" response
  [[ "$response" =~ ^[Yy]$ ]]
}

# Step 1: Uninstall Flux
info "Uninstalling Flux..."
if flux uninstall --silent 2>/dev/null; then
  info "Flux uninstalled successfully."
else
  warn "Flux uninstall failed or Flux was not installed. Continuing..."
fi

# Step 2: Delete flux-system namespace
if kubectl get namespace flux-system &>/dev/null; then
  info "Deleting flux-system namespace..."
  kubectl delete namespace flux-system --timeout=60s
  info "flux-system namespace deleted."
else
  info "flux-system namespace does not exist. Skipping."
fi

# Step 3: Delete all pods in all namespaces (with confirmation)
echo ""
warn "This will delete ALL pods in ALL namespaces (excluding kube-system)."
echo ""
kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -v "^kube-system " || true
echo ""

if confirm "Do you want to delete all pods in all namespaces (excluding kube-system)?"; then
  namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
  for ns in $namespaces; do
    if [[ "$ns" == "kube-system" ]]; then
      continue
    fi
    pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '{print $1}')
    if [[ -n "$pods" ]]; then
      info "Deleting pods in namespace: $ns"
      kubectl delete pods --all -n "$ns" --grace-period=30
    fi
  done
  info "All pods deleted."
else
  info "Skipping pod deletion."
fi

echo ""
info "Cleanup complete."
