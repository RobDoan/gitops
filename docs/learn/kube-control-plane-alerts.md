# Kubernetes control-plane alerts on K3s

Why `KubeSchedulerDown`, `KubeControllerManagerDown`, `KubeProxyDown`, and the `etcd*` alerts fire on our K3s cluster, what each underlying component actually does on a "real" (kubeadm-style) cluster, and what happens when they truly fail.

## TL;DR — disable all four on K3s

On K3s the scheduler, controller-manager, kube-proxy, and (depending on backing store) etcd don't run as separate, scrapeable processes — they are embedded in the single `k3s-server` process. The `kube-prometheus-stack` chart's default scrape jobs and rules can't observe them, so the `*Down` alerts fire forever.

`apps/kube-prometheus-stack/overlays/homelander/helmrelease-patch.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: monitoring
spec:
  values:
    # K3s embeds these in the k3s-server process — no separate scrape targets exist.
    kubeScheduler:
      enabled: false
    kubeControllerManager:
      enabled: false
    kubeProxy:
      enabled: false
    kubeEtcd:
      enabled: false
```

`enabled: false` removes the `Service`, the `ServiceMonitor`, **and** the `PrometheusRule` group for that component, so the `*Down` rules are no longer loaded.

Apply with:

```bash
kubectl kustomize apps/kube-prometheus-stack/overlays/homelander | yq '.spec.values' -
flux reconcile kustomization kube-prometheus-stack --with-source
```

## Why this is a non-issue on K3s

K3s replaces the multi-binary control plane (`kube-apiserver`, `kube-scheduler`, `kube-controller-manager`, `kube-proxy`, `etcd`) with a **single `k3s-server` process** that runs all of those as goroutines. From a Prometheus point of view:

- There is no `Pod` with the labels the chart's `Service` selectors look for, so endpoints are empty.
- The metrics endpoints exist but bind to `127.0.0.1` by default in K3s — not exposed cluster-wide.
- "Is the scheduler up?" reduces to "is k3s-server up?", which is already covered by Node `Ready` status and the kubelet alerts.

So disabling these scrapes on K3s loses **zero** actionable signal.

## What each component does on a real cluster

### 1. `kube-scheduler` → `KubeSchedulerDown`

**Job:** Watches for Pods with `spec.nodeName == ""` (unscheduled). Runs filtering + scoring and writes a binding that sets `nodeName`. That's its entire responsibility — it places Pods on Nodes.

**What "Down" means:** the scheduler process or its `/metrics` endpoint isn't reachable.

**Blast radius if it actually fails:**

- Already-running Pods keep running. **The cluster keeps serving traffic.**
- New Pods, scaling events, replacement Pods after a Node failure, CronJob runs — all stay `Pending` indefinitely.
- It's leader-elected with typically 3 replicas in HA, so "down" usually means *all* replicas are down. One down just triggers a leader re-election, which is fine.
- Recovery: restart it; pending Pods get scheduled within seconds. No data loss.

### 2. `kube-controller-manager` → `KubeControllerManagerDown`

**Job:** Runs ~30 control loops — the "controllers." A non-exhaustive list:

- Deployment controller — creates ReplicaSets from Deployments
- ReplicaSet controller — creates Pods from ReplicaSets
- Node controller — marks Nodes `NotReady` and evicts Pods after the toleration window
- Endpoints / EndpointSlice controller — rebuilds Service backends as Pods come and go
- ServiceAccount + token controller — generates tokens for new ServiceAccounts
- Namespace controller — finalizes namespace deletion
- PersistentVolume controller — binds PVCs to PVs
- Garbage collector — cleans up orphaned objects via owner references
- HorizontalPodAutoscaler controller — scales Deployments based on metrics
- Many others (CronJob, Job, StatefulSet, DaemonSet, certificate signing, ttl-after-finished, …)

**What "Down" means:** controller-manager process / metrics endpoint isn't reachable.

**Blast radius if it actually fails:**

- Running workloads keep running; existing Service → Pod traffic keeps flowing.
- **The cluster stops reacting to change.** Deployments don't roll out. Scaling does nothing. Deleted objects stick around (no GC). Failed Pods aren't replaced. NotReady Nodes don't trigger Pod eviction. New ServiceAccounts don't get tokens. PVCs don't bind. HPAs don't scale. Kubelet client cert rotation breaks.
- Like the scheduler, normally HA + leader-elected; "down" = all replicas down.
- Recovery: restart it; controllers reconcile current state in seconds-to-minutes. The list of "things that should have happened" gets caught up automatically because controllers are **level-triggered** (compare desired vs. actual on every loop), not edge-triggered.

### 3. `kube-proxy` → `KubeProxyDown`

**Job:** A DaemonSet on every Node. Watches Services and Endpoints, programs **iptables** (or **IPVS**, or **nftables**) rules so that traffic to a `ClusterIP` is DNAT'd to one of the backing Pod IPs. It is the data-plane glue for `Service` semantics.

> Note: on K3s, kube-proxy is embedded in the k3s-server/agent. Some Cilium/Calico setups also use `kubeProxyReplacement` mode where eBPF replaces kube-proxy entirely — same alert behavior, same fix.

**What "Down" means:** the kube-proxy Pod on at least one Node isn't reachable on its `:10249` metrics port.

**Blast radius if it actually fails on a single Node:**

- **Existing connections often keep working** — the iptables/IPVS rules already programmed on that Node stay in place until something refreshes them.
- **What breaks on that Node:** Endpoints changes don't propagate. If a Pod backing a Service dies and a new one comes up, traffic from this Node still goes to the dead IP. New Services aren't routable from this Node. NodePorts on this Node may stop accepting connections.
- Pods on *other* Nodes are unaffected.
- Recovery: `kubectl rollout restart ds/kube-proxy -n kube-system`. Rules get re-synced from current Endpoints state. No data loss.

### 4. `kubeEtcd` → multiple alerts

**Job:** The cluster's source of truth. **Every** Kubernetes object — Pods, Secrets, ConfigMaps, the entire desired state — lives in etcd, a Raft-based distributed key-value store. The API server is the only client; everything else talks through the API server.

**What the various alerts mean:**

| Alert | What it's saying |
|---|---|
| `etcdInsufficientMembers` | Quorum is at risk — for a 3-member cluster, more than 1 member is unhealthy. |
| `etcdNoLeader` | Raft can't elect a leader. **Writes are blocked**; reads from non-leaders still work. |
| `etcdHighNumberOfLeaderChanges` | Leadership flapping — usually network or disk-latency problem; degrades request latency. |
| `etcdHighFsyncDurations` / `etcdHighCommitDurations` | Disk is too slow. etcd needs `<10 ms` p99 fsync; SSDs only. Commits backing up slows everything down. |
| `etcdBackendQuotaLowSpace` / `etcdDatabaseQuotaLowSpace` | DB approaching the size quota (default 2 GiB). Once hit, etcd goes **read-only** until you defrag/compact — this is the most common etcd outage in production. |
| `etcdHighNumberOfFailedGRPCRequests` | Clients (the API server) seeing errors — symptom, look at the others for the cause. |
| `etcdMemberCommunicationSlow` | Peer-to-peer Raft traffic latency between members is high. Network problem. |

**Blast radius if etcd is genuinely broken:**

- **Loss of quorum** = the API server can't read or write. `kubectl` is dead. New Pods can't be created or deleted. Existing Pods keep running on whatever Nodes they're on (kubelet caches its assigned Pods). DNS, networking, Services — all keep working, because **the data plane is independent of etcd**. But you're frozen and flying blind.
- **Disk full / quota hit** = silent slowdown or read-only mode. New writes fail with `mvcc: database space exceeded`. Fix is `etcdctl compact` + `etcdctl defrag`.
- **Total etcd loss without a backup** = the cluster is bricked. Workloads keep running on the Nodes until something restarts them, but the cluster state is gone. Restoring from a snapshot is the only recovery — which is why etcd snapshot policy is the single most important thing about any non-managed control plane.

## Summary: severity of a real outage

| Component | Running workloads | New changes (deploys, scaling, scheduling) | Cluster destroyed? |
|---|---|---|---|
| kube-scheduler | unaffected | blocked (Pending forever) | no |
| kube-controller-manager | unaffected | blocked (no rollouts, no GC, no replacement) | no |
| kube-proxy (per Node) | mostly unaffected | new endpoints don't propagate on that Node | no |
| etcd (quorum lost) | unaffected initially | **everything blocked** | no, recoverable |
| etcd (data loss) | keep running until restart | n/a | **yes** without snapshot |

Scheduler / CM / proxy outages **degrade** the cluster — running things keep running, change stops working. An etcd outage **freezes** the cluster, and a bad-enough etcd outage **destroys** it. That's why on a real cluster these alerts are critical and worth keeping enabled — you can't see these failures from the data plane alone.

On K3s, none of those distinctions apply — k3s-server up/down is observable through the kubelet/Node alerts, and the four scrape jobs above are noise.

## If you wanted real metrics on K3s anyway

Two pieces — only worth it if you actually want scheduler / controller-manager dashboards:

1. On the K3s server node, edit `/etc/rancher/k3s/config.yaml`:

   ```yaml
   kube-scheduler-arg:
     - "bind-address=0.0.0.0"
   kube-controller-manager-arg:
     - "bind-address=0.0.0.0"
   kube-proxy-arg:
     - "metrics-bind-address=0.0.0.0"
   etcd-expose-metrics: true
   ```

   Then `sudo systemctl restart k3s`. Verify with `curl -k https://<node-ip>:10259/metrics` (scheduler), `:10257` (CM), `:10249` (kube-proxy), `:2381` (embedded etcd, plain HTTP).

2. Re-enable in the chart and point at the node IP via the helmrelease patch:

   ```yaml
   spec:
     values:
       kubeScheduler:
         service:
           selector: {}
         endpoints:
           - <control-plane-node-ip>
       kubeControllerManager:
         service:
           selector: {}
         endpoints:
           - <control-plane-node-ip>
       kubeProxy:
         service:
           selector: {}
         endpoints:
           - <control-plane-node-ip>
       kubeEtcd:
         service:
           port: 2381
           targetPort: 2381
         serviceMonitor:
           scheme: http
         endpoints:
           - <control-plane-node-ip>
   ```

This is the "proper" fix but it touches host config (outside the GitOps boundary) and pins endpoint IPs into the patch. For a single-node homelab, **disable is the right call** unless you've already wanted those panels.
