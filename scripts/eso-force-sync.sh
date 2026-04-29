#!/usr/bin/env bash
# eso-force-sync.sh — force every ExternalSecret to re-pull from its store now,
# instead of waiting for refreshInterval. Works by bumping the `force-sync`
# annotation, which ESO watches.
#
# Usage:
#   scripts/eso-force-sync.sh            # all namespaces
#   scripts/eso-force-sync.sh <ns>       # one namespace
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

NS_ARG=(-A)
if [[ $# -gt 0 ]]; then
  NS_ARG=(-n "$1")
fi

STAMP=$(date +%s)
COUNT=0

while read -r ns name; do
  [[ -z "$ns" || -z "$name" ]] && continue
  kubectl annotate externalsecret "$name" -n "$ns" \
    "force-sync=$STAMP" --overwrite >/dev/null
  info "synced $ns/$name"
  COUNT=$((COUNT + 1))
done < <(kubectl get externalsecret "${NS_ARG[@]}" \
           -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}')

if [[ $COUNT -eq 0 ]]; then
  warn "no ExternalSecrets found"
  exit 0
fi

info "annotated $COUNT ExternalSecret(s). Check status:"
echo "  kubectl get externalsecret ${NS_ARG[*]}"
