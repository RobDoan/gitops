# Debug Playbook

A cookbook of diagnostic commands for this cluster, organized by symptom. Each entry shows the command, what it's checking, and how to read the output. All examples are real — they come from incidents that actually happened in this repo.

---

## Table of Contents

1. [CRD / API version issues](#1-crd--api-version-issues) — "no matches for kind X"
2. [Flux Kustomizations stuck or failing](#2-flux-kustomizations-stuck-or-failing)
3. [Flux HelmRelease failures](#3-flux-helmrelease-failures)
4. [External Secrets (ESO) not syncing](#4-external-secrets-eso-not-syncing)
5. [Vault sealed or bootstrap job stuck](#5-vault-sealed-or-bootstrap-job-stuck)
6. [PVC stuck Pending](#6-pvc-stuck-pending)
7. [Helm chart rendered unexpected output](#7-helm-chart-rendered-unexpected-output)
8. [kubectl cp gotchas](#8-kubectl-cp-gotchas)
9. [Getting "everything" in a namespace](#9-getting-everything-in-a-namespace)

---

## 1. CRD / API version issues

**Symptom:** Reconcile error like
```
dry-run failed: no matches for kind "ImagePolicy" in version "image.toolkit.fluxcd.io/v1beta2"
```

### `kubectl api-resources --api-group=<group>`

Lists every resource the cluster currently serves for that group.

```sh
kubectl api-resources --api-group=image.toolkit.fluxcd.io
```

**How to read it:**
- Empty result (header only) → the CRD is **not installed**. You need the controller that ships it.
- Rows present but APIVERSION differs from your manifest → **version mismatch**. Your manifest uses a version the cluster no longer serves (common after a controller upgrade).

**Other groups you'll use on this cluster:**
```sh
kubectl api-resources --api-group=external-secrets.io
kubectl api-resources --api-group=helm.toolkit.fluxcd.io
kubectl api-resources --api-group=cert-manager.io
kubectl api-resources --api-group=monitoring.coreos.com
```

### `kubectl api-versions | grep <group>`

Quicker "which API versions does this group expose?"

```sh
kubectl api-versions | grep image.toolkit
# image.toolkit.fluxcd.io/v1
```

### `kubectl get crd <name> -o yaml`

Shows stored vs served versions, conversion webhooks, and the full schema.

```sh
kubectl get crd imagepolicies.image.toolkit.fluxcd.io -o yaml
```

Look for `.spec.versions[].served` and `.spec.versions[].storage`. The `storage: true` version is what the API server writes to etcd.

---

## 2. Flux Kustomizations stuck or failing

**Symptom:** `flux get kustomization` shows `READY=False` or a resource is "suspended."

### `flux get kustomization <name> -n flux-system`

Single resource status plus revision and message.

```sh
flux get kustomization n8n -n flux-system
```

**Columns:**
- `REVISION` — the Git SHA last reconciled. If it's older than what's in main, source hasn't been re-fetched.
- `SUSPENDED` — if `True`, Flux is ignoring this resource. Nothing will reconcile until you resume.
- `READY` — overall health.
- `MESSAGE` — last success or failure reason.

### `flux resume kustomization <name> -n flux-system`

Un-suspends a resource so Flux will reconcile it again.

```sh
flux resume kustomization vault -n flux-system
```

If you try to reconcile a suspended resource directly, you get `resource is suspended`. Resume first.

### `flux reconcile kustomization <name> -n flux-system --with-source`

Forces a fetch-and-apply immediately instead of waiting for the interval.

```sh
flux reconcile kustomization n8n -n flux-system --with-source
```

`--with-source` first re-fetches the `GitRepository`; without it, you reconcile against whatever source-controller last fetched.

Add `--timeout=5m` for visibility if the rollout takes a while.

### `kubectl -n flux-system logs deploy/kustomize-controller --tail=100`

The authoritative source for "why did my Kustomization fail?" — the CLI summary is usually a condensed version of what's here.

```sh
kubectl -n flux-system logs deploy/kustomize-controller --tail=100 | grep -i error
```

### `flux get all -A | grep -v True`

One-liner to list every Flux resource that is NOT ready across the cluster.

```sh
flux get all -A | grep -v True
```

If only the header prints, everything is green.

---

## 3. Flux HelmRelease failures

**Symptom:** HelmRelease shows `READY=False` with "Helm upgrade failed" or "stalled resources."

### `kubectl get helmrelease <name> -n <ns> -o jsonpath='{.status}' | python3 -m json.tool`

Full status including release history (each attempt with version number, config digest, success/fail).

```sh
kubectl get helmrelease n8n -n n8n -o jsonpath='{.status}' | python3 -m json.tool
```

**What to look for:**
- `conditions[]` — current Ready state
- `history[]` — every release attempt, chronologically. A `status: failed` entry tells you where it broke.
- `.upgradeFailures` / `.installFailures` — hit the retry cap and Flux stops trying. Suspend + resume clears it.

### `kubectl describe helmrelease <name> -n <ns>`

Events + last Helm log lines. The bottom section contains the actual Helm CLI output.

```sh
kubectl describe helmrelease n8n -n n8n | tail -40
```

### `helm get values <name> -n <ns>`

Shows the effective values Flux actually passed to Helm — after merging base + overlay patches. Critical for "why is the chart rendering this way?"

```sh
helm get values n8n -n n8n
```

### `helm get manifest <name> -n <ns>`

The fully rendered manifests Helm produced. Use this to confirm the chart actually created what you expect.

```sh
helm get manifest n8n -n n8n > /tmp/rendered.yaml
```

### Clearing a stuck HelmRelease

If retries are exhausted, suspend + resume resets the counter:

```sh
flux suspend helmrelease n8n -n n8n
flux resume helmrelease n8n -n n8n
```

---

## 4. External Secrets (ESO) not syncing

**Symptom:** `ExternalSecret` shows `SecretSyncedError`, or the K8s Secret isn't picking up Vault changes.

### `kubectl get externalsecret <name> -n <ns>`

Status at a glance.

```sh
kubectl get externalsecret n8n-secrets -n n8n
```

**Status values:**
- `SecretSynced` ✅ — all data resolved, K8s Secret written.
- `SecretSyncedError` ❌ — one or more `data[]` entries failed. Check describe for which one.

### `kubectl describe externalsecret <name> -n <ns>`

Event log with the specific error per `data[]` index.

```sh
kubectl describe externalsecret n8n-secrets -n n8n
```

Common messages:
- `cannot find secret data for key: "X"` → the **property** (not path) named X doesn't exist on the Vault secret. Case-sensitive.
- `permission denied` → AppRole policy doesn't grant access to that path.
- `lease expired` / `403` → AppRole secret_id expired; re-run the bootstrap job to rotate.

### Force an immediate sync

ESO's `refreshInterval` (often 1h) means changes take up to an hour. To trigger now:

```sh
kubectl annotate externalsecret n8n-secrets -n n8n \
  force-sync=$(date +%s) --overwrite
```

Bumping **any** annotation makes ESO reconcile within seconds.

### Verify the K8s Secret got the new value

```sh
kubectl get secret n8n-secrets -n n8n \
  -o jsonpath='{.data.N8N_ENCRYPTION_KEY}' | base64 -d
```

Compare against what's in Vault. If they match, ESO did its job.

### After a Secret changes, restart the consumer pod

Env vars set via `valueFrom.secretKeyRef` are read at process start only:

```sh
kubectl rollout restart deployment/<name> -n <ns>
```

---

## 5. Vault sealed or bootstrap job stuck

**Symptom:** Bootstrap job pod runs forever logging "waiting for Vault to be unsealed" — or ESO fails with auth errors.

### `kubectl exec -n vault vault-0 -- vault status`

Check seal state directly from the Vault pod.

```sh
kubectl exec -n vault vault-0 -- vault status
```

**Key field:** `Sealed`. If `true`, Vault won't answer any reads/writes until you provide unseal keys.

### Unseal Vault

Use 3 of the 5 unseal keys from your `vault-init-<cluster>.json`:

```sh
kubectl exec -n vault vault-0 -- vault operator unseal <key1>
kubectl exec -n vault vault-0 -- vault operator unseal <key2>
kubectl exec -n vault vault-0 -- vault operator unseal <key3>
```

After the third, `vault status` should show `Sealed: false`.

### Re-run bootstrap job manually

Jobs can't be restarted in place. Delete and re-apply, or clone:

```sh
# Option A: delete and re-apply via Flux
kubectl delete job vault-bootstrap -n vault
flux reconcile kustomization vault -n flux-system --with-source

# Option B: clone the job under a new name
kubectl create job vault-bootstrap-manual \
  --from=job/vault-bootstrap -n vault
```

Watch it run:
```sh
kubectl logs -n vault -f job/vault-bootstrap
```

### Inspect what's actually in Vault

Port-forward and query directly when ESO complains about a missing property:

```sh
kubectl -n vault port-forward svc/vault 8200:8200 &

export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(jq -r '.root_token' vault-init-homelander.json)

vault kv get -format=json secret/n8n | jq '.data.data | keys'
```

The returned keys must **exactly match** (case-sensitive) the `property:` values in your ExternalSecrets.

### Update a Vault secret without losing other fields

`vault kv put` replaces the whole secret. Use `patch` to add/update single fields:

```sh
vault kv patch secret/n8n encryption_key="new-key-value"
```

---

## 6. PVC stuck Pending

**Symptom:** `kubectl get pvc` shows `STATUS: Pending` and the app won't start properly.

### `kubectl describe pvc <name> -n <ns>`

Events tell you exactly why it's pending.

```sh
kubectl describe pvc n8n -n n8n
```

Common reasons:
- `waiting for first consumer to be created before binding` — storage class uses `WaitForFirstConsumer`; normal until a pod mounts it.
- `provisioning failed` — the CSI driver failed. Check driver logs.
- `no persistent volumes available` — static PVs don't match selectors.

### Check if anything is actually using it

```sh
kubectl describe pvc <name> -n <ns> | grep "Used By"
```

If `Used By: <none>` and the storage class is `WaitForFirstConsumer`, the bug is **upstream** — the Deployment/StatefulSet isn't referencing the PVC. Inspect the pod's volumes:

```sh
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.volumes}' | python3 -m json.tool
```

If you see `emptyDir: {}` where you expect `persistentVolumeClaim:`, the chart or manifest isn't wired correctly. (In this repo: n8n's chart needs `main.persistence.type: dynamic` in addition to `enabled: true`.)

### Check storage class behavior

```sh
kubectl get sc
```

`VOLUMEBINDINGMODE=WaitForFirstConsumer` means the PVC intentionally stays Pending until a pod tries to mount it. Not a bug.

---

## 7. Helm chart rendered unexpected output

**Symptom:** Chart options seem set correctly but the resulting resource doesn't have what you configured.

### Pull the chart locally and read the templates

```sh
# For OCI charts
helm pull oci://8gears.container-registry.com/library/n8n \
  --version 2.0.1 --untar --untardir /tmp/chart

# Inspect
ls /tmp/chart/n8n/templates/
cat /tmp/chart/n8n/values.yaml
```

The template files show exactly when a block is rendered vs skipped. Grep for the helper that's not doing what you expect:

```sh
grep -A 20 'define "n8n.pvc"' /tmp/chart/n8n/templates/_helpers.tpl
```

Real example: n8n's `_helpers.tpl` only mounts the PVC if `persistence.type == "dynamic"`. Setting just `enabled: true` creates the PVC but the Deployment still uses `emptyDir`. Only a template read reveals this.

### Render the chart with your values (no cluster needed)

```sh
helm template n8n /tmp/chart/n8n \
  --values <(helm get values n8n -n n8n | tail -n +2) \
  > /tmp/rendered.yaml
```

Compare `/tmp/rendered.yaml` with what's actually in the cluster (`helm get manifest n8n -n n8n`) to spot drift.

---

## 8. kubectl cp gotchas

**Symptom:** Backup/restore doesn't behave as expected — files end up nested or missing.

### "tar: removing leading '/' from member names" is a warning, not an error

This always prints when copying absolute paths. Ignore it unless the backup directory is actually empty.

### Copying a directory **into** an existing directory nests it

```sh
# If /home/node/.n8n already exists, this creates
# /home/node/.n8n/n8n-backup/ — nested, not merged.
kubectl cp ./n8n-backup n8n/$POD:/home/node/.n8n
```

**Workaround 1** — delete the target first so nothing exists there:
```sh
kubectl exec -n n8n $POD -- rm -rf /home/node/.n8n
kubectl cp ./n8n-backup n8n/$POD:/home/node/.n8n
```

**Workaround 2** — use tar streaming to avoid the nesting behavior entirely:
```sh
# Backup (contents directly into ./backup)
kubectl exec -n n8n $POD -- tar -C /home/node/.n8n -cf - . \
  | tar -xf - -C ./backup

# Restore (contents directly into .n8n)
tar -C ./backup -cf - . \
  | kubectl exec -i -n n8n $POD -- tar -C /home/node/.n8n -xf -
```

---

## 9. Getting "everything" in a namespace

`kubectl get all` is **incomplete**. It excludes ConfigMaps, Secrets, Ingresses, PVCs, ExternalSecrets, HelmReleases, and every CRD.

### Actually list every namespaced resource

```sh
kubectl api-resources --verbs=list --namespaced -o name \
  | xargs -n1 -I{} sh -c 'kubectl get {} -n <namespace> --ignore-not-found -o name 2>/dev/null' \
  | sort -u
```

Slow (one API call per resource type) but thorough.

### Practical "everything that matters in this repo"

```sh
kubectl get all,ingress,secret,configmap,pvc,\
externalsecrets,helmrelease,kustomization \
  -n <namespace>
```

### Interactive

```sh
k9s -n <namespace>
```

Switch resource types with `:<resource><Enter>` (e.g. `:externalsecrets`).

---

## General flow for any Flux issue

When a Kustomization or HelmRelease fails, walk through in order:

1. `flux get kustomization <name> -n flux-system` → top-level state
2. `flux get helmrelease <name> -n <ns>` → if a HelmRelease is involved
3. `kubectl describe <kind> <name> -n <ns>` → events
4. `kubectl -n flux-system logs deploy/kustomize-controller --tail=100` → controller logs
5. `kubectl api-resources --api-group=<group>` → CRD version sanity check
6. Pod-level: `kubectl get pods -n <ns>`, `describe`, `logs`

Most issues resolve at one of those steps. If none of them point at the cause, suspect drift between what Git says vs what's on the cluster — `kubectl diff` against the rendered manifest usually reveals it.
