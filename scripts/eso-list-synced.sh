#!/usr/bin/env bash
# eso-list-synced.sh — show what ESO has synced from Vault into Kubernetes.
# For each ExternalSecret, prints its target Secret, sync status, last sync
# time, and the list of keys (values are NEVER printed).
#
# Usage:
#   scripts/eso-list-synced.sh          # all namespaces
#   scripts/eso-list-synced.sh <ns>     # one namespace
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NS_ARG=(-A)
if [[ $# -gt 0 ]]; then
  NS_ARG=(-n "$1")
fi

FMT='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.target.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.refreshTime}{"\n"}{end}'

while IFS=$'\t' read -r ns name target ready refreshed; do
  [[ -z "$ns" || -z "$name" ]] && continue
  target="${target:-$name}"

  case "$ready" in
    True)  status="${GREEN}Ready${NC}" ;;
    False) status="${RED}NotReady${NC}" ;;
    *)     status="${YELLOW}${ready:-Unknown}${NC}" ;;
  esac

  echo -e "── ${ns}/${name} → Secret/${target}  [${status}]  refreshed=${refreshed:-never}"

  if ! keys=$(kubectl get secret "$target" -n "$ns" \
                -o go-template='{{range $k, $_ := .data}}    - {{$k}}{{"\n"}}{{end}}' \
                2>/dev/null); then
    echo -e "    ${YELLOW}(target Secret not found)${NC}"
    continue
  fi
  if [[ -z "$keys" ]]; then
    echo "    (no keys)"
  else
    echo "$keys"
  fi
done < <(kubectl get externalsecret "${NS_ARG[@]}" -o jsonpath="$FMT")
