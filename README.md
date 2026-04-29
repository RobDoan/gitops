# GitOps Multi-Cluster

FluxCD-managed Kubernetes infrastructure and applications for two clusters:

| Cluster | Type | Storage | Domains | Certs |
|---------|------|---------|---------|-------|
| **rackspace** | Cloud (Rackspace) | `ssd` | `*.quybits.com` | Let's Encrypt |
| **homelander** | Homelab (K3s) | `local-path` | `*.homelander.local` | Self-signed CA |

### Homelander — Public access (via Cloudflare Tunnel)

A Cloudflare Tunnel (`infrastructure/cloudflared/`) exposes homelander services on the public internet without requiring inbound ports. Routing: Cloudflare → cloudflared (in-cluster) → ingress-nginx → service.

| Service | LAN | Public |
|---|---|---|
| n8n | https://n8n.homelander.local | https://n8n-home.quybits.com |
| grafana | https://grafana.homelander.local | https://grafana-home.quybits.com |
| qdrant | https://qdrant.homelander.local | https://qdrant-home.quybits.com |
| royal-dispatch | https://royal-dispatch.homelander.local | https://royal-dispatch-home.quybits.com |
| royal-dispatch admin | https://royal-dispatch-admin.homelander.local | https://royal-dispatch-admin-home.quybits.com |

> Hostnames are first-level under `quybits.com` so Cloudflare's free Universal SSL covers them. Bootstrap script: `scripts/cloudflared-bootstrap.sh` (idempotent, re-run for tunnel rotations or to add new hosts).

## Repository Structure

```
clusters/
├── rackspace/          # Flux entrypoint for rackspace cluster
└── homelander/         # Flux entrypoint for homelander cluster

apps/
├── qdrant/
│   ├── base/           # Common HelmRelease, Ingress, ExternalSecret
│   └── overlays/
│       ├── rackspace/  # ssd storage, qdrant.quybits.com
│       └── homelander/ # local-path storage, qdrant.homelander.local
├── grafana/
│   ├── base/
│   └── overlays/
│       ├── rackspace/
│       └── homelander/
└── n8n/
    ├── base/
    └── overlays/
        ├── rackspace/
        └── homelander/

infrastructure/
├── cert-manager/             # cert-manager operator
├── cert-manager-issuers/
│   ├── base/
│   └── overlays/
│       ├── rackspace/        # Let's Encrypt ACME
│       └── homelander/       # Self-signed CA chain
├── ingress-nginx/            # Ingress controller (shared)
├── external-secrets/         # ESO operator (shared)
├── eso-store/                # ClusterSecretStore (shared)
└── vault/
    ├── base/
    └── overlays/
        ├── rackspace/        # ssd storage, vault.quybits.com
        └── homelander/       # local-path storage, vault.homelander.local

namespaces/                   # Namespace definitions (shared)
```

## Quick Reference Commands

### Switching Clusters

```bash
# List available contexts
kubectx

# Switch to a cluster
kubectx homelander
kubectx speedybite-qdoan-5   # rackspace context name
```

### Flux Status

```bash
# Check all Flux kustomizations
flux get kustomizations

# Check all Helm releases
kubectl get helmrelease -A

# Force reconciliation
flux reconcile kustomization flux-system --with-source
```

### Kustomize Build (Local Validation)

```bash
# Validate app overlays
kubectl kustomize apps/qdrant/overlays/rackspace
kubectl kustomize apps/qdrant/overlays/homelander

kubectl kustomize apps/grafana/overlays/rackspace
kubectl kustomize apps/grafana/overlays/homelander

kubectl kustomize apps/n8n/overlays/rackspace
kubectl kustomize apps/n8n/overlays/homelander

# Validate infrastructure overlays
kubectl kustomize infrastructure/vault/overlays/rackspace
kubectl kustomize infrastructure/vault/overlays/homelander

kubectl kustomize infrastructure/cert-manager-issuers/overlays/rackspace
kubectl kustomize infrastructure/cert-manager-issuers/overlays/homelander
```

### Vault

```bash
# Check vault status
kubectl exec -n vault vault-0 -- vault status

# Unseal vault after restart
./scripts/vault-unseal.sh vault-init.json

# Read a secret (requires root token)
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$(cat vault-init.json | jq -r '.root_token') \
  vault kv get secret/grafana
```

### Secrets (External Secrets Operator)

```bash
# Check sync status
kubectl get externalsecret -A

# Force re-sync a secret
kubectl annotate externalsecret -n grafana grafana-secrets \
  force-sync=$(date +%s) --overwrite
```

### Certificates

```bash
# Check certificate status
kubectl get certificate -A

# Check pending challenges
kubectl get challenges -A

# Describe a failing cert
kubectl describe certificate -n grafana grafana-tls
```

### Debugging

```bash
# Pods not starting
kubectl describe pod -n <namespace> <pod-name>
kubectl logs -n <namespace> <pod-name>

# HelmRelease failing
kubectl describe helmrelease -n <namespace> <name>

# Kustomization stuck
flux get kustomization <name> -o yaml

# Ingress not working
kubectl get ingress -A
kubectl describe ingress -n <namespace> <name>
```

### Homelander — K3s Specific

```bash
# Check nodes
kubectx homelander && kubectl get nodes

# K3s service logs (on server node)
sudo journalctl -u k3s -f

# Restart K3s (on server node)
sudo systemctl restart k3s
```

## Setup Guides

- [Rackspace cluster setup](docs/setup/README.md) — full reinstall from zero
- [Homelab blog post](docs/blog/setup-homelabs.md) — K3s homelab setup
- [Self-signed certs](docs/blog/self-signed-certs-homelab.md) — why and how for homelab TLS

## Architecture Docs

- [Multi-cluster storage design](docs/superpowers/specs/2026-04-14-multi-cluster-storage-design.md)
- [Infrastructure overlays design](docs/superpowers/specs/2026-04-14-infra-overlays-design.md)
