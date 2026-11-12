# `20-logstash.yaml`

**Resources defined:** 1x `ConfigMap`, 1x `Deployment`, 1x `Service`

## Purpose

Runs Logstash, the pipeline that receives logs from every Filebeat pod,
parses/enriches the ones it recognizes, and writes everything to
Elasticsearch under the right index. This is the "transform" step between
raw log shipping (Filebeat) and storage/search (Elasticsearch).

## `ConfigMap` (`logstash-pipeline`)

Holds the actual pipeline definition (`logstash.conf`) as inline YAML text,
mounted into the Logstash container as a file (see the `Deployment` section
below). This is the Kubernetes-native equivalent of the standalone
[`../logstash/pipeline/logstash.conf`](../logstash/pipeline/logstash.conf)
used by the local Docker Compose stack - see
[`../logstash/pipeline/logstash.conf.md`](../logstash/pipeline/logstash.conf.md)
for how the two differ and why.

**`input` block**: a `beats` input listening on port `5044` - this is the
Logstash Beats protocol port that every Filebeat pod ships to (see
`output.logstash.hosts` in `40-filebeat.yaml`).

**`filter` block**: `if [kubernetes][namespace] == "sample" and
[kubernetes][container][name] == "sample"` - only the sample nginx app's log
lines get grok-parsed; everything else (kube-system components, node-system
journald logs, etc.) passes through unparsed as a raw `message` field. Inside
the condition:
- `grok { match => { "message" => "%{COMBINEDAPACHELOG}" } }` - parses an
  nginx/Apache-style combined access log line into structured fields. Logstash
  8.x's `grok` filter is ECS-compatible by default, so the output fields are
  e.g. `http.response.status_code`, `http.request.method`, `url.original`,
  `user_agent.original`, `source.address` - not the legacy flat
  `clientip`/`verb`/`response` names you might expect from older Logstash
  versions or online examples.
- `date { match => [...] }` - parses the log line's own timestamp (e.g.
  `10/Nov/2026:07:37:17 +0000`) into Logstash's `@timestamp` field, so
  Kibana's time-based filtering/sorting reflects when the request actually
  happened, not when Logstash processed it.

**`output` block**: routes documents to one of three indices, checked in
order:
1. `[@metadata][beat] == "metricbeat"` - metrics from `50-metricbeat.yaml`
   (node/pod/container/event metrics, not logs) -> `k8s-metrics-%{+YYYY.MM.dd}`.
   `[@metadata][beat]` is set automatically by the Logstash `beats` input
   itself based on which Beat shipped the event (Filebeat vs. Metricbeat) -
   no custom field needs to be added on the shipping side for this check.
2. `[log_type] == "node-system"` (the custom field Filebeat's journald inputs
   stamp - see `40-filebeat.yaml`) - node kubelet/containerd logs ->
   `k8s-system-logs-%{+YYYY.MM.dd}`.
3. everything else (container logs, any namespace) -> `k8s-logs-%{+YYYY.MM.dd}`.

The `%{+YYYY.MM.dd}` suffix creates one index per day, which is the standard
ELK pattern for easy retention management (e.g. deleting old daily indices).

## `Deployment` (`logstash`)

- **`strategy.type: Recreate`** (not the default `RollingUpdate`): on a
  small/tightly-packed cluster, `RollingUpdate`'s temporary surge pod (one
  extra replica briefly running alongside the old one) can get stuck
  `Pending` with `Insufficient cpu` if there's no spare capacity for both at
  once - this hit Logstash specifically once Metricbeat's extra DaemonSet/
  Deployment pods (`50-metricbeat.yaml`) ate the remaining headroom. Same
  underlying class of problem as Elasticsearch's PVC-driven deadlock (see
  `10-elasticsearch.md`), different trigger (CPU vs. volume contention) -
  `Recreate` sidesteps both by freeing the old pod's resources first.
- `env.xpack.monitoring.enabled=false` - disables Logstash's built-in
  monitoring (which would otherwise also try to write to Elasticsearch);
  not needed for this small/practice setup.
- `resources.requests.cpu: 150m` - kept modest for the same reason as
  Elasticsearch's (see `10-elasticsearch.md`): leaves CPU *request* headroom
  on a small 2-node cluster for the Filebeat/Metricbeat DaemonSets to be
  schedulable.
- `volumeMounts`/`volumes`: mounts the `logstash-pipeline` ConfigMap at
  `/usr/share/logstash/pipeline`, the directory Logstash auto-loads
  `*.conf` files from on startup.

**Important**: Logstash does **not** hot-reload this pipeline if you change
the ConfigMap and re-apply - you must
`kubectl rollout restart deployment logstash -n logging` afterwards (see the
main [README](README.md)'s "Pick up config changes" step).

## `Service` (`logstash`)

Default `ClusterIP`, port `5044`. Filebeat pods reach this at
`logstash.logging.svc.cluster.local:5044` (the DNS name used in
`40-filebeat.yaml`'s `output.logstash.hosts`).
