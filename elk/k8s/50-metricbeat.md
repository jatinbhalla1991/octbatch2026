# `50-metricbeat.yaml`

**Resources defined:** 1x `ServiceAccount`, 1x `ClusterRole`, 1x
`ClusterRoleBinding`, 2x `ConfigMap`, 1x `DaemonSet`, 1x `Deployment`

## Purpose

Runs Metricbeat's `kubernetes` module to collect cluster metrics - node CPU/
memory usage, pod CPU/memory usage, container statistics, and Kubernetes
events - and ships them to Elasticsearch (via Logstash) for visualization in
Kibana, alongside the logs Filebeat ships (`40-filebeat.yaml`). Logs tell you
*what happened*; these metrics tell you *how much resource it used* and
*what the cluster itself did* (scheduling, restarts, etc. via events).

## Why two workloads instead of one

Unlike Filebeat (a single `DaemonSet`), this file splits Metricbeat across
**two** workloads because its metricsets have fundamentally different scopes:

- **`DaemonSet` (`metricbeat`)** - the `node`, `system`, `pod`, `container`,
  and `volume` metricsets all read from the local node's kubelet HTTPS API
  (`https://${NODE_NAME}:10250/stats/summary`). A pod on node A physically
  cannot see node B's kubelet stats, so this has to run once per node - same
  reasoning as Filebeat being a DaemonSet.
- **`Deployment`, 1 replica (`metricbeat-event`)** - the `event` metricset
  watches the Kubernetes API for cluster-wide Events (e.g. pod scheduled,
  image pulled, liveness probe failed). Events aren't node-local, so running
  this as a DaemonSet would make every node's copy report (and duplicate)
  every event in the entire cluster. A single replica is enough.

## RBAC (`ServiceAccount` + `ClusterRole` + `ClusterRoleBinding`)

Both workloads share one `ServiceAccount`/`ClusterRole`. Compared to
Filebeat's `ClusterRole` (`40-filebeat.yaml`), this adds one extra
permission: `get` on `nodes/stats` - the RBAC subresource that authorizes
calling the kubelet's `/stats/summary` endpoint (which the `node`/`system`/
`pod`/`container`/`volume` metricsets all depend on). `get`/`list`/`watch` on
`nodes`/`namespaces`/`pods` covers metadata enrichment (`add_metadata: true`
in the config); `events` covers the `event` metricset.

## `ConfigMap` (`metricbeat-daemonset-config`) + `DaemonSet` (`metricbeat`)

The `kubernetes` module is configured with `metricsets: [node, system, pod,
container, volume]`, polling every `10s`. `hosts: ["https://${NODE_NAME}:10250"]`
targets the kubelet running on the *same* node Metricbeat is scheduled on
(via the `NODE_NAME` downward-API env var, same pattern as
`40-filebeat.yaml`). `bearer_token_file` uses the pod's own auto-mounted
`ServiceAccount` token to authenticate to the kubelet - no extra Secret or
volume needed, Kubernetes projects that token into every pod by default.
`ssl.verification_mode: "none"` skips TLS cert verification for the
kubelet's (typically self-signed) certificate - acceptable for this
quick-start/practice stack, same caveat as `xpack.security.enabled=false`
elsewhere in this repo.

`resources.requests` match Filebeat's footprint (`100m`/`100Mi`) since every
node already runs Filebeat too - keeping this small matters even more here,
since it's now two DaemonSets competing for the same tight CPU budget. See
the Troubleshooting section in [README.md](README.md).

## `ConfigMap` (`metricbeat-deployment-config`) + `Deployment` (`metricbeat-event`)

Same `kubernetes` module, but with only `metricsets: [event]` and no
`hosts`/kubelet config - the event metricset talks to the Kubernetes API
server (already permitted via the shared `ClusterRole`), not to any kubelet.

## Output routing

Both ConfigMaps point `output.logstash.hosts` at the same Logstash `Service`
Filebeat uses (`logstash.logging.svc.cluster.local:5044`). Logstash tells
Metricbeat's documents apart from Filebeat's using the `[@metadata][beat]`
field - set automatically by the Logstash `beats` input based on which Beat
shipped the event, no custom field needed here - and routes them to a
separate `k8s-metrics-*` index. See [`20-logstash.md`](20-logstash.md) for the
exact conditional.
