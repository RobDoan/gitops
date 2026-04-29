#!/usr/bin/env bash
# flux-trigger-update.sh — force a Flux image-automation cycle and wait for the
# rollout. Rescans the registry, runs ImageUpdateAutomation (commits if the tag
# changed), pulls the new commit, reconciles the Kustomization, then watches
# every Deployment in <namespace> that uses the ImagePolicy's image.
#
# Assumes ImageRepository / ImagePolicy / ImageUpdateAutomation / Kustomization
# all share <flux-name> and live in flux-system.
#
# Usage:
#   scripts/flux-trigger-update.sh <namespace> <flux-name>
#
# Example:
#   scripts/flux-trigger-update.sh personal-site personal-site
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()  { echo -e "${YELLOW}[FAIL]${NC} $1" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $(basename "$0") <namespace> <flux-name>"

NS="$1"
NAME="$2"
FLUX_NS="flux-system"
TIMEOUT="5m"

command -v flux    >/dev/null || die "flux CLI not found"
command -v kubectl >/dev/null || die "kubectl not found"
command -v jq      >/dev/null || die "jq not found"

for kind in imagerepository imagepolicy imageupdateautomation kustomization; do
  kubectl -n "$FLUX_NS" get "$kind" "$NAME" >/dev/null 2>&1 \
    || die "$kind/$NAME not found in $FLUX_NS"
done

info "rescanning registry (ImageRepository/$NAME)"
flux reconcile image repository "$NAME" -n "$FLUX_NS"

info "running ImageUpdateAutomation/$NAME (commits if tag changed)"
flux reconcile image update "$NAME" -n "$FLUX_NS"

info "pulling latest git revision"
flux reconcile source git flux-system -n "$FLUX_NS"

info "reconciling Kustomization/$NAME"
flux reconcile kustomization "$NAME" -n "$FLUX_NS"

LATEST=$(kubectl -n "$FLUX_NS" get imagepolicy "$NAME" -o json \
           | jq -r 'if .status.latestRef
                    then "\(.status.latestRef.name):\(.status.latestRef.tag)"
                    else (.status.latestImage // "") end')
[[ -n "$LATEST" ]] || { warn "ImagePolicy has not resolved a latest tag yet"; exit 0; }
IMAGE_BASE="${LATEST%:*}"
ok "ImagePolicy resolved: $LATEST"

DEPLOYMENTS=()
while IFS= read -r d; do
  [[ -n "$d" ]] && DEPLOYMENTS+=("$d")
done < <(kubectl -n "$NS" get deploy -o json \
           | jq -r --arg img "$IMAGE_BASE" \
               '.items[] | select(any(.spec.template.spec.containers[]; .image | startswith($img + ":"))) | .metadata.name')

if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
  warn "no deployments in $NS use $IMAGE_BASE — nothing to roll out"
  exit 0
fi

for d in "${DEPLOYMENTS[@]}"; do
  info "waiting for rollout: $NS/$d (timeout $TIMEOUT)"
  kubectl -n "$NS" rollout status "deploy/$d" --timeout="$TIMEOUT"
  running=$(kubectl -n "$NS" get deploy "$d" \
              -o jsonpath='{.spec.template.spec.containers[*].image}')
  ok "$NS/$d → $running"
done
