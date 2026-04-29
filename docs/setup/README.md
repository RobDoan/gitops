# Cluster Setup — Complete Reinstall Guide

This guide walks through every step to set up the cluster from zero.
Follow in order — each section depends on the previous one completing successfully.

---

## Prerequisites

You need these tools installed locally before starting.

```bash
# Check versions
kubectl version --client
flux version
helm version
jq --version
```

| Tool | Install |
|------|---------|
| kubectl | https://kubernetes.io/docs/tasks/tools/ |
| flux | `brew install fluxcd/tap/flux` |
| helm | `brew install helm` |
| jq | `brew install jq` |

You also need:
- A GitHub personal access token with `repo` scope
- Your Rackspace cluster kubeconfig downloaded from the Rackspace portal
- Your domain (`quybits.com`) managed in Cloudflare

---

## Step 1 — Connect kubectl to the Rackspace Cluster

Download the kubeconfig from Rackspace portal:
**Rackspace portal → Kubernetes → your cluster → Download kubeconfig**

```bash
# Tell kubectl to use the downloaded kubeconfig
export KUBECONFIG=~/Downloads/kubeconfig.yaml
```
> This sets your local kubectl to talk to the Rackspace cluster instead of any local cluster.

```bash
# Verify kubectl is pointing at the right cluster
kubectl cluster-info
```
> Should show the Rackspace API server address, not localhost.

```bash
# Verify you can list nodes
kubectl get nodes
```
> Should show 1 node in Ready state.

---

## Step 2 — Bootstrap Flux

Flux is the GitOps operator that watches this Git repository and applies everything to the cluster automatically.

```bash
# Set your GitHub credentials
export GITHUB_TOKEN=<your-github-personal-access-token>
export GITHUB_USER=RobDoan
```
> The token needs `repo` scope so Flux can read the repository and write a deploy key.

```bash
# Bootstrap Flux onto the cluster
flux bootstrap github \
  --owner=${GITHUB_USER} \
  --repository=gitops-rackspace \
  --branch=main \
  --path=./clusters/rackspace \
  --personal
```
> This installs Flux controllers into the `flux-system` namespace, adds a deploy key to the GitHub repository, and commits a `flux-system/` folder to the repo. From this point, Flux watches for new commits and applies them automatically.

```bash
# Verify Flux controllers are running
kubectl get pods -n flux-system
```
> Should show `source-controller`, `kustomize-controller`, `helm-controller`, and `notification-controller` all Running.

---

## Step 3 — Watch the Initial Reconciliation

Flux will now start applying everything in order according to the `dependsOn` chain. This takes several minutes.

```bash
# Watch all Kustomizations reconcile (run this and leave it open)
watch flux get kustomizations
```
> You should see components go Ready=True one by one in this order:
> `namespaces` → `cert-manager` → `cert-manager-issuers` → `ingress-nginx`, `external-secrets` → `vault` → `eso-store` → `grafana`, `qdrant`, `n8n`

```bash
# Watch all Helm releases install (open a second terminal)
watch kubectl get helmrelease -A
```
> Each HelmRelease will show `Helm install succeeded` when done.

**Expected final state (all Ready=True):**
```
cert-manager          True
cert-manager-issuers  True
external-secrets      True
ingress-nginx         True
vault                 True
eso-store             True
namespaces            True
```

> Note: `grafana`, `qdrant`, and `n8n` will stay not-ready until Vault is initialized (Step 5).

---

## Step 4 — Get the LoadBalancer IP and Configure DNS

Once ingress-nginx is Ready, it gets a public IP from Rackspace.

```bash
# Get the external IP assigned to the ingress
kubectl get svc -n ingress-nginx ingress-nginx-controller
```
> Look for the `EXTERNAL-IP` column. It will be something like `23.253.121.115`.
> If it shows `<pending>`, wait 1-2 minutes and run again.

**Set DNS records in Cloudflare:**

Go to **Cloudflare → quybits.com → DNS → Records** and add these 4 `A` records:

| Type | Name | Value | Proxy |
|------|------|-------|-------|
| A | `vault` | `<EXTERNAL-IP>` | DNS only (grey cloud) |
| A | `grafana` | `<EXTERNAL-IP>` | DNS only (grey cloud) |
| A | `n8n` | `<EXTERNAL-IP>` | DNS only (grey cloud) |
| A | `qdrant` | `<EXTERNAL-IP>` | DNS only (grey cloud) |

> **Important:** Use "DNS only" (grey cloud), NOT "Proxied" (orange cloud). cert-manager's Let's Encrypt HTTP-01 challenge must reach your server directly. If Cloudflare proxies the traffic, certificate issuance will fail.

```bash
# Verify DNS is resolving (run after a minute or two)
dig +short vault.quybits.com
dig +short grafana.quybits.com
dig +short n8n.quybits.com
dig +short qdrant.quybits.com
```
> Each should return your LoadBalancer IP.

---

## Step 5 — Initialize and Unseal Vault

Vault starts sealed (encrypted, unusable) after every fresh install. You must initialize it once to generate the unseal keys, then unseal it.

```bash
# Initialize Vault — generates 3 unseal keys, requires 2 to unseal
# SAVE THIS OUTPUT. If you lose it, you lose access to all secrets forever.
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=3 \
  -key-threshold=2 \
  -format=json > vault-init.json
```
> Creates `vault-init.json` locally containing:
> - `unseal_keys_b64` — 3 keys (need any 2 to unseal)
> - `root_token` — full admin access token
>
> **Never commit this file to Git.** Store it in a password manager or secure offline storage.

```bash
# Verify the file has what you expect
cat vault-init.json | jq '{root_token: .root_token, key_count: (.unseal_keys_b64 | length)}'
```
> Should show `key_count: 3`.

```bash
# Unseal Vault using 2 random keys from vault-init.json
./scripts/vault-unseal.sh vault-init.json
```
> Picks 2 of the 3 keys at random and applies them. Vault moves from Sealed=true to Sealed=false.

```bash
# Verify Vault is unsealed
kubectl exec -n vault vault-0 -- vault status
```
> Look for `Initialized: true` and `Sealed: false`.

---

## Step 6 — Run the Vault Bootstrap Job

The bootstrap job sets up the secrets engine, auth policies, and AppRole credentials that External Secrets Operator uses to read secrets from Vault.

```bash
# Give the bootstrap job access to Vault using the root token
kubectl create secret generic vault-root-token \
  -n vault \
  --from-literal=token=$(cat vault-init.json | jq -r '.root_token')
```
> Creates a K8s secret that the bootstrap Job reads as an environment variable (`VAULT_TOKEN`). The job needs root access to configure Vault policies.

```bash
# Run the bootstrap job
kubectl apply -f infrastructure/vault/bootstrap-job.yaml
```
> Submits the Job to Kubernetes. The job will start a pod and run the bootstrap script.

```bash
# Watch the bootstrap job logs until it says "Bootstrap complete"
kubectl logs -n vault job/vault-bootstrap -f
```
> Expected output:
> ```
> Vault is unsealed.
> Success! Enabled the kv-v2 secrets engine at: secret/
> Success! Enabled approle auth method at: approle/
> Success! Uploaded policy: eso-policy
> ...
> secret/vault-approle-credentials created
> Bootstrap complete. Update secret values in Vault before going live.
> ```

**What the bootstrap job creates:**
- KV v2 secrets engine at `secret/` — where all app secrets are stored
- AppRole auth — how ESO authenticates to Vault (not root token, scoped credentials)
- Per-app read policies — n8n can only read `secret/data/n8n`, grafana only `secret/data/grafana`, etc.
- `vault-approle-credentials` K8s secret in `external-secrets` namespace — ESO uses this to connect
- Placeholder secrets for each app (`changeme` values — replace in Step 7)

---

## Step 7 — Set Real Secret Values in Vault

The bootstrap job seeded placeholder values. Replace them before the services go live.

```bash
# Set your root token for the commands below
export VAULT_ROOT_TOKEN=$(cat vault-init.json | jq -r '.root_token')
```

```bash
# Generate a strong 32-character encryption key for n8n
openssl rand -hex 16
```
> n8n uses this key to encrypt stored credentials. If you lose it, saved credentials in n8n become unreadable. Keep a copy in your password manager.

```bash
# Set n8n secrets
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$VAULT_ROOT_TOKEN \
  vault kv put secret/n8n \
  encryption_key="<output-from-openssl-above>"
```
> Stores the n8n encryption key in Vault at `secret/data/n8n`.

```bash
# Set Grafana admin credentials
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$VAULT_ROOT_TOKEN \
  vault kv put secret/grafana \
  admin_user="admin" \
  admin_password="<your-strong-password>"
```
> Grafana uses these to create the initial admin account. Change `admin_password` to something strong.

```bash
# Set Qdrant API key
kubectl exec -n vault vault-0 -- \
  env VAULT_TOKEN=$VAULT_ROOT_TOKEN \
  vault kv put secret/qdrant \
  api_key="<your-strong-api-key>"
```
> Qdrant uses this key to authenticate API requests. Generate with `openssl rand -hex 32`.

---

## Step 8 — Trigger External Secrets Sync

External Secrets Operator syncs secrets from Vault into K8s Secrets on a 1-hour interval. Force an immediate sync:

```bash
# Force ESO to re-sync all ExternalSecrets now
kubectl annotate externalsecret -n grafana grafana-secrets \
  force-sync=$(date +%s) --overwrite
kubectl annotate externalsecret -n n8n n8n-secrets \
  force-sync=$(date +%s) --overwrite
kubectl annotate externalsecret -n qdrant qdrant-secrets \
  force-sync=$(date +%s) --overwrite
```
> The annotation triggers an immediate reconciliation instead of waiting up to 1 hour.

```bash
# Verify secrets were created
kubectl get secret grafana-secrets -n grafana
kubectl get secret n8n-secrets -n n8n
kubectl get secret qdrant-secrets -n qdrant
```
> Each should show `TYPE: Opaque` and an `AGE` of a few seconds.

```bash
# Check ExternalSecret sync status
kubectl get externalsecret -A
```
> `READY` column should be `True` and `STATUS` should be `SecretSynced` for all three.

---

## Step 9 — Verify All Services Are Running

```bash
# Check all pods across app namespaces
kubectl get pods -n grafana
kubectl get pods -n n8n
kubectl get pods -n qdrant
kubectl get pods -n vault
```
> All pods should be `Running` and `1/1 Ready`.

```bash
# Check TLS certificates were issued by Let's Encrypt
kubectl get certificate -A
```
> `READY` should be `True` for each certificate. If still `False`, check challenges:

```bash
# If certificates are not ready, check ACME challenge status
kubectl get challenges -A
```
> Challenges should complete within 1-2 minutes once DNS is resolving correctly.

```bash
# Check ingress resources have TLS configured
kubectl get ingress -A
```
> Each service should show its hostname and `ADDRESS` matching the LoadBalancer IP.

---

## Step 10 — Smoke Test Each Service

```bash
# Test each service responds over HTTPS
curl -I https://vault.quybits.com
curl -I https://grafana.quybits.com
curl -I https://n8n.quybits.com
curl -I https://qdrant.quybits.com
```
> Each should return `HTTP/2 200` (or a redirect to login). If you get a TLS error, the certificate may still be issuing — wait a minute and retry.

Open in browser:

| Service | URL | Login |
|---------|-----|-------|
| Vault | https://vault.quybits.com | Token: root token from `vault-init.json` |
| Grafana | https://grafana.quybits.com | admin / password from Step 7 |
| n8n | https://n8n.quybits.com | Create account on first visit |
| Qdrant | https://qdrant.quybits.com | API key from Step 7 |

---

## After a Cluster Restart (Vault Reseals on Reboot)

Vault seals itself whenever its pod restarts. After any cluster reboot or pod eviction, unseal it again:

```bash
# Check if Vault is sealed
kubectl exec -n vault vault-0 -- vault status | grep Sealed
```

```bash
# Unseal if needed (Sealed: true)
./scripts/vault-unseal.sh vault-init.json
```
> Until Vault is unsealed, ESO cannot sync secrets and the application pods will fail to start.

---

## Troubleshooting Quick Reference

| Symptom | First command to run |
|---------|---------------------|
| Kustomization stuck not-ready | `flux get kustomizations` — check MESSAGE column |
| HelmRelease failing | `kubectl describe helmrelease <name> -n <namespace>` |
| Pod not starting | `kubectl describe pod -n <namespace> <pod-name>` |
| Secret not synced | `kubectl describe externalsecret -n <namespace> <name>` |
| Certificate not issuing | `kubectl describe challenge -A` |
| Vault unreachable | `kubectl exec -n vault vault-0 -- vault status` |
| DNS not resolving | `dig +short grafana.quybits.com` |

---

## Flux Useful Commands

### Check Status

```bash
# Check all Kustomizations
flux get kustomizations

# Check all HelmReleases across namespaces
flux get helmrelease -A

# Check a specific HelmRelease
flux get helmrelease <name> -n <namespace>

# Check Flux source repositories
flux get sources helm -A
flux get sources git -A
```

### Reconcile (Force Sync)

```bash
# Force Flux to re-sync a HelmRelease immediately
flux reconcile helmrelease <name> -n <namespace>

# Force Flux to re-sync a Kustomization
flux reconcile kustomization <name>

# Force Flux to re-pull from the Git source
flux reconcile source git flux-system
```

### Suspend / Resume

```bash
# Pause Flux management of a release (useful for debugging)
flux suspend helmrelease <name> -n <namespace>

# Resume Flux management
flux resume helmrelease <name> -n <namespace>

# Suspend + resume to clear stale errors
flux suspend helmrelease <name> -n <namespace> && flux resume helmrelease <name> -n <namespace>
```

### Debugging

```bash
# View Flux logs
flux logs --level=error

# View logs for a specific controller
flux logs --kind=HelmRelease --name=<name> --namespace=<namespace>

# Check why a HelmRelease failed
kubectl describe helmrelease <name> -n <namespace>

# Reset a stuck/failed Helm release (deletes Helm history, Flux will reinstall)
kubectl delete secret -n <namespace> -l owner=helm,name=<name>
flux reconcile helmrelease <name> -n <namespace>
```

### Uninstall

```bash
# Remove a HelmRelease (Flux will delete the Helm release from the cluster)
flux delete helmrelease <name> -n <namespace>

# Uninstall Flux entirely from the cluster
flux uninstall
```

---

## Important Files

| File | Description | Security |
|------|-------------|----------|
| `vault-init.json` | Vault unseal keys and root token | **Never commit. Store offline.** |
| `scripts/vault-unseal.sh` | Script to unseal Vault after reboots | Safe to commit |
| `infrastructure/vault/bootstrap-job.yaml` | One-time Vault setup job | Safe to commit |
| `clusters/rackspace/` | Flux Kustomization CRs | Safe to commit |

```bash
# Make sure vault-init.json is gitignored
echo "vault-init.json" >> .gitignore
git add .gitignore && git commit -m "chore: ignore vault-init.json"
```
