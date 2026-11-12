# ELK Stack on AKS - Logging Pipeline Walkthrough

**Goal:** understand how a centralized logging pipeline (Filebeat -> Logstash
-> Elasticsearch -> Kibana) fits together, deploy it as native Kubernetes
workloads on AKS, and learn to diagnose the Kubernetes scheduling/rollout
problems you'll hit along the way.

**What you'll learn:**
- How log shipping, parsing/enrichment, indexing, and visualization are split
  across four separate components, and why each one is a separate workload.
- How to deploy stateful (`PersistentVolumeClaim`-backed) and stateless
  workloads on AKS with plain Kubernetes manifests (no Helm).
- How to query, live-tail, and start building dashboards from logs in Kibana.
- How to recognize and fix common Kubernetes rollout/scheduling deadlocks on a
  small/resource-constrained cluster.

Version: `8.15.0` across all components. `xpack.security.enabled=false` is set
on Elasticsearch/Kibana to keep this a quick-start/practice stack without
TLS/cert setup - don't reuse that setting as-is for anything production-facing.

## How it fits together

```
Filebeat (DaemonSet, 1 pod per node)             Metricbeat (DaemonSet + Deployment)
   |  tails container logs + node journald           |  polls kubelet stats (node/pod/container/
   |  (kubelet/containerd)                           |  volume) + watches the API for events
   v                                                  v
                     Logstash (Deployment)
                        |  parses/enriches (e.g. nginx access-log grok -> structured fields)
                        |  routes to an index based on log type / beat
                        v
                     Elasticsearch (Deployment + PersistentVolumeClaim)
                        |  stores and indexes the documents
                        v
                     Kibana (Deployment, LoadBalancer Service)
                              search, filter, live-tail, and visualize in the browser
```

Each component is a separate Kubernetes workload on purpose: Filebeat and
Metricbeat's node-level metricsets must run on *every* node (hence
`DaemonSet`), Metricbeat's cluster-wide event metricset must run exactly once
(hence a separate single-replica `Deployment`), while Logstash/Elasticsearch/
Kibana are each a single logical service (hence `Deployment`). Manifests live
in `k8s/` and deploy everything into a `logging` namespace.

## Step-by-step: deploy on AKS

### Step 1 - Provision the AKS cluster

**Purpose:** you need a Kubernetes cluster to run any of this on. Skip this
step if you already have one.

**Commands:**
```powershell
cd ..\kuberntesterraform\Terraform
terraform init
terraform apply -var-file="dev.tfvars"
```

`dev.tfvars` provisions an AKS cluster named `aks-demo-cluster` in the `demo`
resource group (adjust the tfvars if you use different names).

### Step 2 - Point kubectl at the cluster

**Purpose:** every `kubectl`/`az` command below targets whatever cluster your
local `kubectl` context currently points at - this step makes that the AKS
cluster you just provisioned (or an existing one).

**Commands:**
```powershell
az aks get-credentials --resource-group demo --name aks-demo-cluster
```

**Verify:**
```powershell
kubectl config current-context   # should print aks-demo-cluster
kubectl get nodes                # should list your AKS node(s) as Ready
```

### Step 3 - Deploy the sample app (traffic source)

**Purpose:** a logging pipeline needs something producing logs to be useful
to learn from. The sample app is an nginx Deployment that logs an access-log
line for every HTTP request it serves - that's the "traffic" this walkthrough
observes end-to-end.

**Commands:**
```powershell
kubectl apply -f ..\docker\menifest.yaml
```

**Verify:**
```powershell
kubectl get pods -n sample   # 2 pods, STATUS Running
```

### Step 4 - Deploy the ELK stack, in order

**Purpose:** the manifests are numbered (`00-`, `10-`, `20-`...) because later
ones depend on earlier ones - e.g. Logstash's `Service` DNS name must exist
before Filebeat's config can reference it, and the `logging` namespace must
exist before anything can be created inside it. Applying them in order avoids
transient "namespace not found" errors (though `kubectl apply` is also safe to
re-run/re-order if you forget).

**Commands:**
```powershell
cd ..\elk
kubectl apply -f k8s\00-namespace.yaml
kubectl apply -f k8s\10-elasticsearch.yaml
kubectl apply -f k8s\20-logstash.yaml
kubectl apply -f k8s\30-kibana.yaml
kubectl apply -f k8s\40-filebeat.yaml
kubectl apply -f k8s\50-metricbeat.yaml
```

**Verify:**
```powershell
kubectl get pods -n logging    # wait until all pods are Running/Ready
```

### Step 5 - Access Kibana

**Purpose:** Kibana is the browser UI you'll use for everything from here on
- it needs a reachable address first.

**Commands:**
```powershell
kubectl get svc -n logging kibana   # grab the EXTERNAL-IP once provisioned
```

Kibana is exposed via a `LoadBalancer` `Service` (an Azure Load Balancer with a
public IP, matching the pattern used for the sample app's `Service`). Swap the
`Service` `type` to `ClusterIP` + `kubectl port-forward` instead if you don't
want a public IP.

**Verify:** browse to `http://<EXTERNAL-IP>:5601` - you should see the Kibana
home page.

### Step 6 - Create data views

**Purpose:** Kibana doesn't know which Elasticsearch index (or which field is
the timestamp) to search until you tell it, via a **data view**. Without one,
Discover has nothing to show.

**Steps:**
1. **☰ menu > Management > Stack Management > Data Views > Create data view**.
2. Create one named/titled `k8s-logs-*` (matches every pod/container log
   index, across all namespaces) with time field `@timestamp`.
3. Create a second one for `k8s-system-logs-*` (node kubelet/containerd logs)
   the same way.
4. Create a third one for `k8s-metrics-*` (Metricbeat's node/pod/container/
   volume/event metrics) the same way.

### Step 7 - Explore logs in Discover

**Purpose:** this is how you actually read, filter, and search logs day to
day - the equivalent of `grep`-ing a log file, but across every pod/node in
the cluster, in one place.

**Steps:**
1. **☰ menu > Analytics > Discover** (or `http://<EXTERNAL-IP>:5601/app/discover`).
2. Top-left **data view** dropdown: pick `k8s-logs-*` or `k8s-system-logs-*`.
3. Top-right **time range** picker: widen it (e.g. "Last 1 hour") if you don't
   see any hits - it defaults to a short window.
4. Use the KQL search bar to filter down. Useful fields populated by this
   stack's Filebeat/Logstash config:
   - `kubernetes.namespace: "sample"` or `kubernetes.namespace: "kube-system"`
   - `kubernetes.pod.name: "coredns*"`
   - `kubernetes.container.name: "sample"`
   - `log_type: "node-system"` (only in `k8s-system-logs-*`)
   - `systemd_unit: "kubelet"` or `systemd_unit: "containerd"`
   - `message: "error"` (free-text search across the raw log line)
   - `http.response.status_code: 200` (nginx hits only - see Step 8)
5. Click the **>** arrow on the left of any row to expand it and see every
   field on that document (or the **JSON** tab for the raw document). Hover a
   field in the left-hand field list and click **+** to add it as a column
   (e.g. `kubernetes.pod.name`, `kubernetes.container.name`, `message`).
6. **Save search** (top toolbar) to reuse a filter/column layout later, or
   build a dashboard from **☰ menu > Analytics > Dashboard** using
   visualizations (e.g. a count-by-`kubernetes.namespace` bar chart) sourced
   from the same data views.

### Step 8 - Test the pipeline / monitor live logs

**Purpose:** prove to yourself the whole chain actually works end-to-end -
request hits the app -> app logs it -> Filebeat tails it -> Logstash
parses/ships it -> it's searchable in Elasticsearch/Kibana within seconds -
and learn how to watch that happen live instead of just checking after the
fact.

**Commands:**
```powershell
# 1. generate some traffic against the sample app (from inside the cluster,
#    so it works even if the LoadBalancer's public IP isn't reachable from
#    where you're running this)
kubectl exec -n logging deploy/logstash -- sh -c "for i in 1 2 3 4 5; do curl -s -o /dev/null http://sample.sample.svc.cluster.local/; done"

# 2. tail the raw container logs directly (bypasses ELK entirely - good sanity
#    check that the app is actually logging each request)
kubectl logs -n sample -l app=sample --tail=20 -f

# 3. confirm Elasticsearch received/indexed them
kubectl port-forward -n logging svc/elasticsearch 9200:9200
# in another terminal:
curl "http://localhost:9200/k8s-logs-*/_count" -H "Content-Type: application/json" -d '{"query":{"term":{"kubernetes.namespace.keyword":"sample"}}}'
```

> If you also run the local Docker Compose stack below, it binds Elasticsearch
> to local port 9200 too - use a different local port for the port-forward
> (e.g. `kubectl port-forward -n logging svc/elasticsearch 19200:9200`, then
> query `localhost:19200`) to avoid silently talking to the wrong cluster.

**To monitor logs live in Kibana** instead of the terminal: open **Discover**
(Step 7), pick the `k8s-logs-*` data view, set a short relative time range
(e.g. "Last 15 minutes"), then click the **auto-refresh** clock icon next to
the time range, set an interval (e.g. 5s), and click **Start**. New hits
appear at the top of the results table as they're indexed - typically within
a couple of seconds of the request hitting the pod.

**Why this matters for dashboards:** each nginx access log line is grok-parsed
(Logstash 8.x's `grok` filter is ECS-compatible by default) into structured
fields, so you don't need to parse `message` yourself:
- `http.response.status_code` (number, e.g. `200`/`404`)
- `http.request.method` (e.g. `GET`)
- `url.original` (requested path)
- `user_agent.original`
- `source.address` (client IP)

A date-histogram visualization with **Count** as the metric, filtered to
`kubernetes.namespace: "sample"`, gives hits-over-time; a terms aggregation on
`http.response.status_code` gives a breakdown by status code.

### Step 9 - Pick up config changes

**Purpose:** if you edit the pipeline (`k8s/20-logstash.yaml`) or the
Filebeat inputs (`k8s/40-filebeat.yaml`), Logstash/Filebeat don't hot-reload
their *base* config from a changed `ConfigMap` - you have to restart the
workload, or your edits silently have no effect.

**Commands:**
```powershell
kubectl apply -f k8s\20-logstash.yaml   # or 40-filebeat.yaml
kubectl rollout restart deployment logstash -n logging
kubectl rollout restart daemonset filebeat -n logging
```

## Log sources shipped by Filebeat

- **Container logs, all namespaces** (`k8s-logs-*` index): Filebeat's
  Kubernetes autodiscover with no namespace filter, so this includes the
  `sample` app as well as `kube-system` components (coredns, metrics-server,
  azure-cni, konnectivity-agent, etc.). Filter by `kubernetes.namespace` in
  Kibana to narrow down to a specific namespace.
- **Node system logs** (`k8s-system-logs-*` index): `kubelet.service` and
  `containerd.service` units read directly from each node's systemd journal
  (`journald` input), tagged with `log_type: node-system` and `systemd_unit`.
  These aren't tied to any pod/namespace - they're the node's own OS-level
  logs. Add more `include_matches` entries in the `filebeat-config` ConfigMap
  (`k8s/40-filebeat.yaml`) for other systemd units you want to capture.

> Note: this covers everything visible from inside the cluster/nodes. AKS
> control-plane logs (kube-apiserver, kube-scheduler, kube-controller-manager
> audit logs, etc.) run on Azure-managed infrastructure outside the cluster
> and aren't reachable by Filebeat - shipping those requires a separate Azure
> Monitor **Diagnostic settings** pipeline on the AKS resource.

## Metrics shipped by Metricbeat

Deployed via `k8s/50-metricbeat.yaml`, all land in the **`k8s-metrics-*`**
index (separate from logs), via Metricbeat's `kubernetes` module:

- **Node CPU/memory usage** (`node` metricset) and the kubelet's own
  machine-level view (`system` metricset).
- **Pod CPU/memory usage** (`pod` metricset).
- **Container statistics** (`container` metricset) - per-container CPU,
  memory, and I/O, one level more granular than the pod-level metricset.
- **Volume usage** (`volume` metricset) - PVC capacity/usage, e.g.
  Elasticsearch's `es-data` PVC.
- **Kubernetes events** (`event` metricset) - the same events `kubectl get
  events -A` shows (pod scheduled, image pulled, liveness probe failed,
  etc.), but durably stored and searchable instead of evicted after ~1 hour
  like the live `kubectl` view.

The `node`/`system`/`pod`/`container`/`volume` metricsets run as a
`DaemonSet` (one node's kubelet can only report that node's own stats); the
`event` metricset runs as a separate single-replica `Deployment` (events are
cluster-wide, so running it per-node would duplicate every event). See
[`k8s/50-metricbeat.md`](k8s/50-metricbeat.md) for the full breakdown.

In Kibana, filter `event.dataset` to tell metricsets apart (e.g.
`event.dataset: "kubernetes.pod"`), or `kubernetes.node.name`/
`kubernetes.pod.name` to scope to a specific node/pod. A metric visualization
with **Average** of `kubernetes.pod.cpu.usage.node.pct` (or the equivalent
memory field), split by `kubernetes.pod.name`, gives a per-pod CPU/memory
chart - the metrics equivalent of the hits-over-time chart described in
Step 8 above.

## Troubleshooting

Real problems hit (and fixed in these manifests) while validating this stack
on a small 2-node AKS cluster - each one is a useful lesson in how Kubernetes
scheduling/rollouts actually work:

- **Filebeat `CrashLoopBackOff` with `missing or invalid condition`**: a
  Kubernetes autodiscover `templates` entry needs either a real `condition`
  (e.g. `equals`/`contains`) or no `condition` key at all for a catch-all
  template - an empty `condition: {}` is rejected by Filebeat.
- **Filebeat/Metricbeat DaemonSet pod stuck `Pending`**: on small clusters
  (e.g. 2 nodes / `Standard_D2s_v3`) cumulative pod CPU *requests* can fill a
  node's allocatable CPU before the DaemonSet pod gets scheduled (`kubectl
  describe pod` shows `Insufficient cpu`). `k8s/10-elasticsearch.yaml` and
  `k8s/20-logstash.yaml` intentionally use modest CPU requests (`400m`/`150m`)
  for this reason - lower them further (or Metricbeat's `100m` requests in
  `k8s/50-metricbeat.yaml`) if you hit this on an even smaller cluster.
- **Elasticsearch/Logstash rollout stuck on "Insufficient cpu" or "1 old
  replicas are pending termination"**: two related deadlocks on a
  small/tightly-packed cluster - (a) a single-replica Deployment backed by a
  `ReadWriteOnce` PVC can't do the default `RollingUpdate` (the new pod can't
  mount the volume until the old one releases it, but the old one won't
  terminate until the new one is ready), and (b) even without a PVC, the
  default `RollingUpdate`'s temporary surge pod needs spare CPU that may not
  exist (this is what happened to Logstash once Metricbeat's extra DaemonSet/
  Deployment pods used up the remaining headroom). Both
  `k8s/10-elasticsearch.yaml` and `k8s/20-logstash.yaml` set
  `strategy.type: Recreate` to avoid this - keep that if you change either
  manifest, and consider the same fix for any other single-replica
  `Deployment` you add to this cluster.
- **A multi-replica Deployment rollout stuck on "Insufficient cpu" for the
  surge pod**: the default `RollingUpdate` strategy creates one extra pod
  before removing an old one (`maxSurge: 25%` rounds up to 1), which briefly
  needs spare capacity. `docker/menifest.yaml`'s `sample` Deployment sets
  `maxSurge: 0` / `maxUnavailable: 1` so Kubernetes frees a slot first
  instead.

## Storage

Elasticsearch uses a 10Gi `PersistentVolumeClaim` (`es-data`, no
`storageClassName` set so it provisions an Azure Disk from AKS's default
`StorageClass`), so data survives pod restarts/rescheduling. Resize the
`storage` request in `k8s/10-elasticsearch.yaml` if you need more.

## Tearing down

**Purpose:** reclaim the cluster's CPU/memory/storage once you're done.

**Commands:**
```powershell
kubectl delete -f k8s\40-filebeat.yaml -f k8s\30-kibana.yaml -f k8s\20-logstash.yaml -f k8s\10-elasticsearch.yaml -f k8s\00-namespace.yaml
```

Deleting `00-namespace.yaml` also removes the `es-data` PVC (and its backing
Azure Disk), so only do that once you no longer need the indexed logs.

## Config file reference

Each manifest in `k8s/` has a companion `.md` file explaining that file in
detail (resources defined, purpose of every field, key decisions):

- [`k8s/00-namespace.md`](k8s/00-namespace.md) - the shared `logging` namespace.
- [`k8s/10-elasticsearch.md`](k8s/10-elasticsearch.md) - the `es-data` PVC,
  the single-node Elasticsearch `Deployment`, and its `Service`.
- [`k8s/20-logstash.md`](k8s/20-logstash.md) - the `logstash-pipeline`
  ConfigMap (beats input -> optional nginx grok parsing -> Elasticsearch
  output, routed to `k8s-logs-*` or `k8s-system-logs-*`), the `Deployment`,
  and its `Service`.
- [`k8s/30-kibana.md`](k8s/30-kibana.md) - the Kibana `Deployment` and its
  `LoadBalancer` `Service`.
- [`k8s/40-filebeat.md`](k8s/40-filebeat.md) - the RBAC objects, the
  `filebeat-config` ConfigMap (Kubernetes autodiscover across all namespaces +
  journald inputs for node system logs), and the `DaemonSet`.
- [`k8s/50-metricbeat.md`](k8s/50-metricbeat.md) - the shared RBAC objects,
  the two ConfigMaps (kubelet-sourced node/pod/container/volume metricsets vs.
  the API-sourced event metricset), the `DaemonSet`, and the single-replica
  `Deployment`.

## Local (Docker Compose) - optional, for quick local testing

**Purpose:** try the stack on your machine without a cluster - useful for
quickly iterating on the Logstash pipeline/Filebeat config before deploying
to AKS.

Collects logs from every container on the Docker host (including the `web`,
`backend`, `db` services from `../docker/docker-compose.yaml`) via Filebeat's
Docker autodiscover, ships them through Logstash, and indexes them into
Elasticsearch.

**Commands:**
```powershell
# start the sample app first so there's something to collect logs from
cd ..\docker
docker compose up -d

# then start the ELK stack
cd ..\elk
docker compose up -d
```

- Elasticsearch: http://localhost:9200
- Kibana: http://localhost:5601
- Logstash beats input: `localhost:5044`

In Kibana, create a data view for the `docker-logs-*` index pattern (Stack
Management > Data Views) to start browsing logs.

Config files:
- [`logstash/pipeline/logstash.conf`](logstash/pipeline/logstash.conf) ([explained](logstash/pipeline/logstash.conf.md)) - beats input -> optional nginx grok parsing -> Elasticsearch output
- `filebeat/filebeat.yml` - Docker autodiscover (hints-based, all containers)

## Checkpoints

- [ ] Why does Filebeat run as a `DaemonSet` while Elasticsearch/Logstash/
      Kibana are `Deployment`s?
- [ ] What problem does a Kibana **data view** solve, and why does Discover
      show nothing without one?
- [ ] Why does the Elasticsearch `Deployment` need `strategy.type: Recreate`
      but the `sample` app's Deployment doesn't?
- [ ] Why would a DaemonSet pod get stuck `Pending` even though every node
      shows `Ready`?
- [ ] What's the difference between the `k8s-logs-*` and `k8s-system-logs-*`
      indices, and why are they separate?
- [ ] Why can't this Filebeat setup ship AKS's kube-apiserver/scheduler logs,
      and what would you need instead?
- [ ] Why does Metricbeat's `event` metricset run as a `Deployment` while its
      `node`/`pod`/`container` metricsets run as a `DaemonSet`?
- [ ] What's the difference between what Filebeat ships and what Metricbeat
      ships - could you answer "is the app slow?" with just one of them?
