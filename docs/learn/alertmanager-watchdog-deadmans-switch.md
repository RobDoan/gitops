# Wiring the Alertmanager `Watchdog` alert to a real dead-man's-switch

The `Watchdog` alert was sitting in the firing list on homelander. It looked like an error worth fixing — it isn't an error at all, it's a heartbeat alert that the kube-prometheus-stack chart deliberately keeps firing forever. The actual gap was that it had nowhere useful to go. This is the walkthrough of why it exists, what we found in the repo, and how we closed the loop with healthchecks.io.

## The "alert"

```text
Watchdog
  expr:        vector(1)
  severity:    none
  runbook_url: https://runbooks.prometheus-operator.dev/runbooks/general/watchdog
  summary:     An alert that should always be firing to certify that
               Alertmanager is working properly.
```

`vector(1)` always evaluates to `1`. There is no failure condition. The expression is the entire point — it lets you build a *negative* alarm somewhere outside the cluster: "page me when Watchdog stops arriving."

## What Watchdog actually is — the dead-man's-switch pattern

Every other alert assumes Alertmanager is alive and able to deliver. If Alertmanager itself dies (crashloop, network partition, the whole cluster down), every real alert silently disappears. Watchdog is the inverse: it's a constant heartbeat that exits the cluster, and an external observer expects to receive it. When the heartbeat stops, the external observer pages **you**, because nothing inside the cluster can.

Common external observers:

| Service | Best for |
|---|---|
| healthchecks.io (hosted) | One-person homelab "production." Free tier (20 checks), multi-channel notifications. |
| Dead Man's Snitch | Teams already on PagerDuty. Free tier limited to 1 snitch. |
| Better Uptime / Cronitor / UptimeRobot heartbeat | Generic alternatives — fine if you already use them. |

**Critical rule:** the observer must be physically external to the cluster it watches. Self-hosting healthchecks.io on the same node defeats the entire purpose — it dies with the cluster.

## Phase 1 — confirm what state our cluster was actually in

Before recommending anything, look at what's already wired. The repo's Alertmanager routing lives in `apps/kube-prometheus-stack-config/base/alertmanager-config.yaml` (an `AlertmanagerConfig` CRD, not a giant helm-values block).

```bash
cat apps/kube-prometheus-stack-config/base/alertmanager-config.yaml
```

The interesting bit:

```yaml
routes:
  # Silence the chart's dead-man's-switch alert. Watchdog always fires by
  # design; its value is only realized when routed to an EXTERNAL monitor
  # that expects the heartbeat (e.g. Dead Man's Snitch, healthchecks.io).
  # Until that external hop is wired up, drop it so it stops spamming #alerts.
  - receiver: "null"
    matchers:
      - name: alertname
        value: Watchdog
```

Past-self knew exactly what Watchdog was for and had explicitly silenced it pending the external hop. Layer 1 (real notification path) was already done — `slack-default` and `slack-critical` receivers point at `#alerts` and `#alerts-critical`, sourced from a Vault-backed secret:

```bash
kubectl get externalsecret -n monitoring
```

```text
NAME                 STORE          REFRESH INTERVAL   STATUS
alertmanager-slack   vault-backend  1h                 SecretSynced
```

```bash
kubectl exec -n vault vault-0 -- vault kv list secret/observability
```

```text
Keys
----
loki-s3
slack-webhook
```

So the gap was narrow: build Layer 2 (the external observer) and flip the route from `"null"` to it.

## Phase 2 — pick the observer and wire it

Choices made for a one-person homelab targeting a 1-hour tolerance:

- **healthchecks.io** (hosted) over Dead Man's Snitch (free tier too small) and self-hosted (defeats the purpose).
- A single check named `homelander-alertmanager-watchdog`, schedule **Simple**: period 15 minutes, grace 45 minutes → 60-minute total tolerance from the last good ping to the page.
- healthchecks.io → Slack integration assigned to that check, posting to a dedicated `#healthcheck-io-alert` channel (separate from `#alerts` so cluster-dead notifications can't be lost in normal alert volume).
- Alertmanager pings every 5 minutes — gives 3x redundancy inside the 15-minute period in case any single ping fails to deliver. Healthchecks docs recommend ping frequency ≤ ½ of period; we're at ⅓, well inside the safe range.

Vault layout, mirroring the existing `slack-webhook` convention:

```bash
kubectl exec -n vault vault-0 -- \
  vault kv put secret/observability/healthchecks \
  watchdog_url="https://hc-ping.com/<uuid>"
```

## What we changed in the repo

Three small additions under `apps/kube-prometheus-stack-config/base/`.

**1. New `ExternalSecret` syncing the ping URL** (`externalsecret-healthchecks.yaml`):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: alertmanager-healthchecks
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: alertmanager-healthchecks
    creationPolicy: Owner
  data:
    - secretKey: watchdog_url
      remoteRef:
        key: observability/healthchecks
        property: watchdog_url
```

**2. Add it to the kustomization:**

```diff
 resources:
   - alertmanager-config.yaml
+  - externalsecret-healthchecks.yaml
   - servicemonitors/n8n.yaml
```

**3. Replace the silencing route with a webhook receiver in `alertmanager-config.yaml`:**

```diff
     routes:
-      # Silence the chart's dead-man's-switch alert. ... Until that external
-      # hop is wired up, drop it so it stops spamming #alerts.
-      - receiver: "null"
+      # Watchdog is the chart's dead-man's-switch — always firing by design.
+      # Stream it to healthchecks.io as a heartbeat; if pings stop for >1h,
+      # healthchecks pages us in #healthcheck-io-alert (Alertmanager itself
+      # is down, so its own alerts can't reach us).
+      - receiver: healthchecks-watchdog
         matchers:
           - name: alertname
             value: Watchdog
+        groupWait: 0s
+        groupInterval: 5m
+        repeatInterval: 5m
       - receiver: slack-critical
         matchers:
           - name: severity
             value: critical
   receivers:
     - name: "null"
+    - name: healthchecks-watchdog
+      webhookConfigs:
+        - urlSecret:
+            name: alertmanager-healthchecks
+            key: watchdog_url
+          sendResolved: false
     - name: slack-default
```

The non-default route timing parameters matter:

- `groupWait: 0s` — don't batch the first alert in a group. Send it immediately.
- `groupInterval: 5m` — minimum gap between sending updates for an existing group. Matched to `repeatInterval` for consistency.
- `repeatInterval: 5m` — re-send the same active alert every 5 minutes. This is the heartbeat. Tuned for a homelab tolerance of 1 hour; for tighter SLOs use a smaller value.
- `sendResolved: false` — Watchdog never resolves (it's `vector(1)`), and even if it did, "resolved" would mean Alertmanager is broken, in which case it can't send the resolved notification anyway. Cleaner to suppress.

The `"null"` receiver is left in place for future silencing patterns even though nothing references it now — removing it would be unrelated cleanup.

## Verification

Render the overlay before committing — the cluster has no CI on this repo, so kustomize errors only surface when Flux reconciles:

```bash
kubectl kustomize apps/kube-prometheus-stack-config/overlays/homelander
```

After Flux picks it up:

```bash
flux reconcile kustomization kube-prometheus-stack-config

kubectl get externalsecret -n monitoring alertmanager-healthchecks
# expect STATUS=SecretSynced

kubectl get secret -n monitoring alertmanager-healthchecks \
  -o jsonpath='{.data.watchdog_url}' | base64 -d | head -c 30
# expect: https://hc-ping.com/...

kubectl get alertmanagerconfig -n monitoring royal-dispatch -o yaml \
  | grep -A4 healthchecks-watchdog
```

The healthchecks.io check turns green within ~5 minutes (one Alertmanager group cycle).

**Test the failure path** — this is the part most people skip and regret:

1. Pause the check in the healthchecks.io UI.
2. Wait `period + grace` = 15m + 45m = 60 minutes.
3. Confirm a Slack message lands in `#healthcheck-io-alert`.

If this test never runs, you don't actually know your dead-man's-switch works.

## Lessons

- **Always-firing alerts are not always errors.** `Watchdog` exists to be inverted by an external observer; suppressing it loses end-to-end pipeline coverage.
- **A real notification path (Layer 1) and a dead-man's-switch (Layer 2) are both required.** Layer 2 without Layer 1 monitors an empty pipe; Layer 1 without Layer 2 is invisible if Alertmanager itself dies.
- **The external observer must be external.** Self-hosting it on the same cluster makes the whole loop circular and useless.
- **Mirror existing repo patterns.** The `alertmanager-slack` ExternalSecret + `urlSecret`-from-secret pattern was already established; the healthchecks integration just copied it. Inventing a new pattern here would have added review surface for no reason.
- **Test the failure path explicitly.** "Healthy" pings prove the happy path works; only a deliberate pause proves the actual paging path works.
