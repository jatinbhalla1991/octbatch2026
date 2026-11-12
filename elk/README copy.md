# ELK Stack (Elasticsearch, Logstash, Kibana, Filebeat)

Logging stack for the sample app (`docker/menifest.yaml`). Deployed as native
Kubernetes workloads into an AKS cluster - this is the primary, supported way to
run the stack. Kept in its own folder so it can be deployed independently of the
app it's collecting logs from.

Version: `8.15.0` across all components. `xpack.security.enabled=false` is set on
Elasticsearch/Kibana to keep this a quick-start/practice stack without TLS/cert
setup - don't reuse that setting as-is for anything production-facing.

## Kubernetes / AKS (primary)

Manifests in `k8s/` deploy the whole stack into a `logging` namespace and use a
Filebeat DaemonSet to ship both pod/container logs (from every namespace,
including cluster system components in `kube-system`) and node-level system
logs (kubelet, containerd) into Elasticsearch. Everything - Elasticsearch,
Logstash, Kibana and Filebeat - runs as pods on the AKS cluster; nothing needs
to run locally.

### 1. Provision the AKS cluster

If you don't already have a cluster, provision one with the Terraform in
[`kuberntesterraform/Terraform`](../kuberntesterraform/Terraform):

```powershell
cd ..\kuberntesterraform\Terraform
terraform init
terraform apply -var-file="dev.tfvars"
```

`dev.tfvars` provisions an AKS cluster named `aks-demo-cluster` in the `demo`
resource group (adjust the tfvars if you use different names). Then point
`kubectl` at it:

```powershell
az aks get-credentials --resource-group demo --name aks-demo-cluster
```

### 2. Deploy the sample app

Deploy the sample app so there's something besides system components to look
at in the `k8s-logs-*` logs:

```powershell
kubectl apply -f ..\docker\menifest.yaml
```

### 3. Deploy the ELK stack

```powershell
cd ..\elk
kubectl apply -f k8s\00-namespace.yaml
kubectl apply -f k8s\10-elasticsearch.yaml
kubectl apply -f k8s\20-logstash.yaml
kubectl apply -f k8s\30-kibana.yaml
kubectl apply -f k8s\40-filebeat.yaml
```

```powershell
kubectl get pods -n logging    # wait until all pods are Running/Ready
kubectl get pods -n sample
```

### 4. Access Kibana

Kibana is exposed via a `LoadBalancer` `Service` (an Azure Load Balancer with a
public IP, matching the pattern used for the sample app's `Service`):

```powershell
kubectl get svc -n logging kibana   # grab the EXTERNAL-IP once provisioned
```

Browse to `http://<EXTERNAL-IP>:5601` and create data views for `k8s-logs-*`
(every pod/container across all namespaces) and `k8s-system-logs-*` (node
kubelet/containerd logs) (Stack Management > Data Views) to start browsing
logs. Swap the `Service` `type` to `ClusterIP` + `kubectl port-forward` instead
if you don't want a public IP.

### Log sources shipped by Filebeat

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

### Exploring logs in Kibana

1. Open `http://<EXTERNAL-IP>:5601`, then go to **☰ menu > Analytics > Discover**
   (or browse directly to `http://<EXTERNAL-IP>:5601/app/discover`).
2. Top-left **data view** dropdown: pick `k8s-logs-*` for pod/container logs or
   `k8s-system-logs-*` for node kubelet/containerd logs (create them first - see
   step 4 above - if you haven't already).
3. Top-right **time range** picker: widen it (e.g. "Last 1 hour" or "Last 24
   hours") if you don't see any hits - it defaults to a short window.
4. Use the KQL search bar to filter down. Useful fields populated by this
   stack's Filebeat/Logstash config:
   - `kubernetes.namespace: "sample"` or `kubernetes.namespace: "kube-system"`
   - `kubernetes.pod.name: "coredns*"`
   - `kubernetes.container.name: "sample"`
   - `log_type: "node-system"` (only in `k8s-system-logs-*`)
   - `systemd_unit: "kubelet"` or `systemd_unit: "containerd"`
   - `message: "error"` (free-text search across the raw log line)
5. Click the **>** arrow on the left of any row to expand it and see every
   field on that document (or the **JSON** tab in the expanded view for the
   raw document). Hover a field in the left-hand field list and click **+** to
   add it as a column in the results table (e.g. `kubernetes.pod.name`,
   `kubernetes.container.name`, `message`).
6. **Save search** (top toolbar) to reuse a filter/column layout later, or
   build a dashboard from **☰ menu > Analytics > Dashboard** using
   visualizations (e.g. a count-by-`kubernetes.namespace` bar chart) sourced
   from the same data views.

### Testing the pipeline / monitoring live logs

Quick end-to-end check that logs are actually flowing, using the sample nginx
app as a traffic source:

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

To monitor logs live in Kibana instead of the terminal: open **Discover** (see
above), pick the `k8s-logs-*` data view, and in the top-right time menu pick a
short relative range (e.g. "Last 15 minutes") plus the **auto-refresh** clock
icon next to it (e.g. every 5s). New hits appear at the top of the results
table as they're indexed - typically within a couple of seconds of the
request hitting the pod.

Each nginx access log line is grok-parsed (Logstash 8.x's `grok` filter is ECS-
compatible by default) into structured fields, so you don't need to parse
`message` yourself - useful for a "hits" dashboard:
- `http.response.status_code` (number, e.g. `200`/`404`)
- `http.request.method` (e.g. `GET`)
- `url.original` (requested path)
- `user_agent.original`
- `source.address` (client IP)

A date-histogram visualization with **Count** as the metric, filtered to
`kubernetes.namespace: "sample"`, gives hits-over-time; a terms aggregation on
`http.response.status_code` gives a breakdown by status code.

### Picking up config changes

Filebeat/Logstash don't hot-reload their base config from a changed
ConfigMap, so after re-applying `k8s/20-logstash.yaml` or `k8s/40-filebeat.yaml`
restart the workloads to pick up the new pipeline/inputs:

```powershell
kubectl rollout restart deployment logstash -n logging
kubectl rollout restart daemonset filebeat -n logging
```

### Troubleshooting

Gotchas hit (and fixed in these manifests) while validating the stack on a
small 2-node AKS cluster:

- **Filebeat `CrashLoopBackOff` with `missing or invalid condition`**: a
  Kubernetes autodiscover `templates` entry needs either a real `condition`
  (e.g. `equals`/`contains`) or no `condition` key at all for a catch-all
  template - an empty `condition: {}` is rejected by Filebeat.
- **Filebeat DaemonSet pod stuck `Pending`**: on small clusters (e.g. 2 nodes /
  `Standard_D2s_v3`) cumulative pod CPU *requests* can fill a node's
  allocatable CPU before the DaemonSet pod gets scheduled (`kubectl describe
  pod` shows `Insufficient cpu`). `k8s/10-elasticsearch.yaml` and
  `k8s/20-logstash.yaml` intentionally use modest CPU requests (`400m`/`150m`)
  for this reason - lower them further if you hit this on an even smaller
  cluster.
- **Elasticsearch rollout stuck on "1 old replicas are pending termination"**:
  a single-replica Deployment backed by a `ReadWriteOnce` PVC can't do the
  default `RollingUpdate` - the new pod can't mount the volume until the old
  one releases it, but the old one won't terminate until the new one is
  ready. `k8s/10-elasticsearch.yaml` sets `strategy.type: Recreate` to avoid
  this deadlock - keep that if you change the Elasticsearch manifest.
- **A multi-replica Deployment rollout stuck on "Insufficient cpu" for the
  surge pod**: the default `RollingUpdate` strategy creates one extra pod
  before removing an old one (`maxSurge: 25%` rounds up to 1), which briefly
  needs spare capacity. `docker/menifest.yaml`'s `sample` Deployment sets
  `maxSurge: 0` / `maxUnavailable: 1` so Kubernetes frees a slot first
  instead.

### Storage

Elasticsearch uses a 10Gi `PersistentVolumeClaim` (`es-data`, no
`storageClassName` set so it provisions an Azure Disk from AKS's default
`StorageClass`), so data survives pod restarts/rescheduling. Resize the
`storage` request in `k8s/10-elasticsearch.yaml` if you need more.

### Tearing down

```powershell
kubectl delete -f k8s\40-filebeat.yaml -f k8s\30-kibana.yaml -f k8s\20-logstash.yaml -f k8s\10-elasticsearch.yaml -f k8s\00-namespace.yaml
```

Deleting `00-namespace.yaml` also removes the `es-data` PVC (and its backing
Azure Disk), so only do that once you no longer need the indexed logs.

Config files:
- `k8s/20-logstash.yaml` (`logstash-pipeline` ConfigMap) - beats input -> optional nginx grok parsing -> Elasticsearch output, routed to `k8s-logs-*` or `k8s-system-logs-*`
- `k8s/40-filebeat.yaml` (`filebeat-config` ConfigMap) - Kubernetes autodiscover (all namespaces) + journald inputs for node system logs

## Local (Docker Compose) - optional, for quick local testing

Only needed if you want to try the stack on your machine without a cluster.
Collects logs from every container on the Docker host (including the `web`,
`backend`, `db` services from `../docker/docker-compose.yaml`) via Filebeat's
Docker autodiscover, ships them through Logstash, and indexes them into
Elasticsearch.

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
- `logstash/pipeline/logstash.conf` - beats input -> optional nginx grok parsing -> Elasticsearch output
- `filebeat/filebeat.yml` - Docker autodiscover (hints-based, all containers)
