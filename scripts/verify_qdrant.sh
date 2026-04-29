#!/bin/bash
set -e

# Verify Rackspace Overlay
if [ ! -d "apps/qdrant/overlays/rackspace" ]; then
    echo "Error: Rackspace overlay directory not found."
    exit 1
fi
RACKSPACE_OUTPUT=$(kustomize build apps/qdrant/overlays/rackspace)
echo "$RACKSPACE_OUTPUT" | grep -q "storageClassName: ssd" || (echo "Rackspace storage class check failed"; exit 1)
echo "$RACKSPACE_OUTPUT" | grep -q "host: qdrant.quybits.com" || (echo "Rackspace host check failed"; exit 1)
echo "Rackspace overlay verified."

# Verify Homelander Overlay
if [ ! -d "apps/qdrant/overlays/homelander" ]; then
    echo "Error: Homelander overlay directory not found."
    exit 1
fi
HOMELANDER_OUTPUT=$(kustomize build apps/qdrant/overlays/homelander)
echo "$HOMELANDER_OUTPUT" | grep -q "storageClassName: local-path" || (echo "Homelander storage class check failed"; exit 1)
echo "$HOMELANDER_OUTPUT" | grep -q "host: qdrant.homelander.local" || (echo "Homelander host check failed"; exit 1)
echo "Homelander overlay verified."
