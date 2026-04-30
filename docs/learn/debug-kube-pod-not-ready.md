# Debugging `KubePodNotReady` — completed pods and orphaned cert-manager challenges

A `KubePodNotReady` page on homelander turned out to be two unrelated problems sharing the same alert. This is the walkthrough — what fired, what each command was doing and why, and the two root causes that fell out.

## The alert

```
KubePodNotReady
  expr: sum by (namespace, pod) (kube_pod_status_ready{condition="false"}) == 1
  for:  15m
  severity: warning
```

Five firings (homelander):

| Pod | Age | State |
|---|---|---|
| `monitoring/loki-bucket-init-bhl44` | 54m | firing |
| `vault/cm-acme-http-solver-4ptds` | 4d 9h | firing |
| `qdrant/cm-acme-http-solver-dclpd` | 4d 9h | firing |
| `grafana/cm-acme-http-solver-88w98` | 4d 9h | firing |
| `vault/vault-bootstrap-9wbhg` | 8m | pending |

Two clearly different shapes — one cluster of 4d-old `cm-acme-http-solver-*` pods, and a couple of one-off Job pods. Treat them as two separate investigations.

## Why this query catches more than it sounds like

The expression is just "`Ready` condition is `False` for 15m." There is **no phase filter**. A pod in `Succeeded`/`Completed` has `Ready=False` forever — the Ready condition is only `True` while a pod is `Running` and passing its readiness checks. So any Completed Job pod that lingers past 15 minutes will trip this alert. Keep that in mind before assuming "not ready" means "broken."

## Phase 1 — confirm the basics

```bash
kubectl config current-context
# → homelander
```

Always do this first on a multi-cluster setup. The CLAUDE.md convention is rackspace = deprecated, homelander = primary, and they use different storage classes, domains, and issuers. Pointing diagnostic commands at the wrong cluster wastes time.

```bash
kubectl get pod -n monitoring loki-bucket-init-bhl44 -o wide
# → Error from server (NotFound)

kubectl get pod -n vault vault-bootstrap-9wbhg -o wide
# → Error from server (NotFound)
```

Both Job pods *named in the alert* don't exist anymore. The Jobs themselves do, and have produced new pods since:

```bash
kubectl get jobs -n vault
# vault-bootstrap   Complete   1/1   9s   8m40s
kubectl get pods -A | grep -E 'loki-bucket-init|vault-bootstrap'
# vault/vault-bootstrap-m52bv         0/1   Completed   0   9m9s
# monitoring/loki-bucket-init-klt65   0/1   Completed   0   7m58s
```

So the Jobs are running fine; what's pathological is that their pods stay around in `Completed` state long enough to trip the alert. That points at `spec.ttlSecondsAfterFinished` on the Job, not at anything wrong with the workload.

The 4d-old solver pods, by contrast, do still exist:

```bash
kubectl get pod -n vault cm-acme-http-solver-4ptds -o wide
# 0/1   Completed   0   13d
```

`Completed` is interesting here too — these are HTTP-01 solver pods, which normally serve an HTTP server while the challenge runs. If they exited, the challenge either succeeded (in which case cert-manager should have cleaned them up) or the challenge is stuck and cert-manager doesn't know to GC.

## Phase 2 — chase the cert-manager half

```bash
kubectl get challenges,orders,certificates -A
```

Output condensed:

```
NAMESPACE   CHALLENGE                                  STATE     DOMAIN
grafana     grafana-tls-1-3497741904-691309173         pending   grafana.quybits.com
qdrant      qdrant-tls-1-1196453714-4260096175         pending   qdrant.quybits.com
vault       vault-tls-1-1875066828-2045187413          pending   vault.quybits.com

NAMESPACE   CERTIFICATE                READY   SECRET
grafana     grafana-tls                True    grafana-tls
qdrant      qdrant-tls                 True    qdrant-tls
vault       vault-tls                  True    vault-tls
…
```

Two surprises:
1. The Challenges are for `*.quybits.com` — but homelander uses `*.homelander.local` for LAN ingress. Those domains shouldn't be involved here at all.
2. The Certificates are `Ready=True` despite the Challenges being stuck. The certs in the Secrets are valid; they just won't renew via this path.

Get more detail on one Challenge:

```bash
kubectl get challenge -n vault vault-tls-1-1875066828-2045187413 -o yaml
```

The interesting bits:

```yaml
spec:
  authorizationURL: https://acme-v02.api.letsencrypt.org/acme/authz/3242459721/...
  dnsName: vault.quybits.com
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-prod
metadata:
  ownerReferences:
  - kind: ClusterIssuer
    name: letsencrypt-prod
  finalizers:
  - acme.cert-manager.io/finalizer
status:
  reason: 'Waiting for HTTP-01 challenge propagation: failed to perform self check
    GET request "http://vault.quybits.com/.well-known/acme-challenge/...":
    dial tcp: lookup vault.quybits.com on 10.43.0.10:53: no such host'
  state: pending
```

So: the Challenge was created against the real Let's Encrypt ACME endpoint, for a public domain, 13 days ago. It can't propagate because cluster DNS doesn't resolve `vault.quybits.com`. The Challenge has the `acme.cert-manager.io/finalizer` so it can't be GC'd.

Compare with the *current* Certificate spec:

```bash
kubectl get certificate -n vault vault-tls -o jsonpath='{.spec.issuerRef}{"\n"}{.spec.dnsNames}{"\n"}'
# {"group":"cert-manager.io","kind":"ClusterIssuer","name":"letsencrypt-prod"}
# ["vault.homelander.local"]
```

The Certificate today asks for `vault.homelander.local` from a ClusterIssuer named `letsencrypt-prod` — and is `Ready`. That should be impossible for a real Let's Encrypt issuer, since `*.homelander.local` is unroutable from the public internet.

Sanity-check the issuer itself:

```bash
kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.spec}'
# {"ca":{"secretName":"homelander-ca-secret"}}
```

There it is. **The ClusterIssuer named `letsencrypt-prod` is, on homelander, actually a CA issuer using the local self-signed CA.** The name is leftover from the rackspace setup. New Certificates are silently signed by the local CA — that's why every recent cert is `Ready`. ACME is no longer used at all.

But the 3 Challenges from before the issuer was repurposed are still on disk, with finalizers, with `dnsName` and `authorizationURL` frozen at the moment they were created. cert-manager (now in CA mode) doesn't process the ACME finalizer, so they sit there forever. Each Challenge had spawned a solver Pod + Service + Ingress at creation time (you can confirm with `kubectl get ingress -A | grep acme`), and those linger as well — including the Completed pod that trips `KubePodNotReady`.

## Phase 2 — chase the Job half

`vault-bootstrap` and `loki-bucket-init` are both repo-managed Jobs:

```bash
grep -n ttlSecondsAfterFinished infrastructure/vault/base/bootstrap-job.yaml apps/loki/base/minio-bucket-job.yaml
# infrastructure/vault/base/bootstrap-job.yaml:7:  ttlSecondsAfterFinished: 600
# apps/loki/base/minio-bucket-job.yaml:7:          ttlSecondsAfterFinished: 3600
```

`vault-bootstrap` is at 600s (10m) — the alert window is 15m, so the Completed pod is gone before the threshold. That's why it was only `pending` in the alert list, never firing. `loki-bucket-init` is at 3600s (1h) — the pod hangs around four times longer than the alert window, so `KubePodNotReady` fires every reconcile cycle.

There is no underlying workload bug here — just a TTL that doesn't fit the alerting policy.

## Issues found, and fixes

**Issue 1 — orphaned cert-manager Challenges from a repurposed ClusterIssuer.** Three `Challenge` resources from before the rackspace → homelander migration still hold the `acme.cert-manager.io/finalizer`. Their owning Order is gone, the new issuer is CA-mode and doesn't process them, and they keep their solver Pod / Service / Ingress alive in each namespace.

Fix — strip the finalizer and delete:

```bash
for ns in vault qdrant grafana; do
  for ch in $(kubectl get challenge -n "$ns" -o name); do
    kubectl patch -n "$ns" "$ch" --type=merge -p '{"metadata":{"finalizers":[]}}'
    kubectl delete -n "$ns" "$ch" --wait=false
  done
done
```

Cascade GC then removes the solver Pod, Service, and Ingress in each namespace (they're owned by the Challenge). Verify:

```bash
kubectl get challenge -A                       # No resources found
kubectl get ingress -A | grep -i acme || echo "(none)"
kubectl get svc -A     | grep -i acme || echo "(none)"
kubectl get pods -A    | grep -i cm-acme || echo "(none)"
```

Live `*-tls` Secrets and Certificates stay `Ready` — they were already signed by the CA and don't need new Orders.

**Issue 2 — `loki-bucket-init` Job TTL longer than the alert window.** The Completed pod sat for 1h while the alert fires at 15m. Lower it to match the `vault-bootstrap` precedent:

```diff
-  ttlSecondsAfterFinished: 3600
+  ttlSecondsAfterFinished: 600
```

In `apps/loki/base/minio-bucket-job.yaml`. Render and let Flux reconcile:

```bash
kubectl kustomize apps/loki/overlays/homelander | grep -A1 ttlSecondsAfterFinished
flux reconcile kustomization loki --with-source
```

After reconcile, the next bucket-init pod is GC'd at the 10-minute mark — comfortably inside the 15-minute alert window.

## Lessons

- **Read the alert query before acting on the alert text.** "Not ready for 15m" hides the fact that `Completed` Job pods always satisfy this condition. The fix often lives on the Job's TTL, not the workload.
- **Names lie.** `ClusterIssuer/letsencrypt-prod` was rewired to a CA backend during migration but kept its name. Always `kubectl get clusterissuer <name> -o jsonpath='{.spec}'` before assuming the wire protocol.
- **Stuck cert-manager Challenges with `acme.cert-manager.io/finalizer` won't clear themselves once the owning Issuer changes mode.** Strip the finalizer manually; the finalizer is the only thing blocking Kubernetes GC.
- **TTL on Jobs needs to be a function of your alerting policy.** If `KubePodNotReady` is `for: 15m`, every Job in the repo wants `ttlSecondsAfterFinished < 900`. Worth grepping the repo for outliers.
