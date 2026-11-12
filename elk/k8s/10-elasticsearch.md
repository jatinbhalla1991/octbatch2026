# `10-elasticsearch.yaml`

**Resources defined:** 1x `PersistentVolumeClaim`, 1x `Deployment`, 1x `Service`

## Purpose

Runs the single-node Elasticsearch instance that stores and indexes every log
document this stack ships. Everything else (Logstash writing, Kibana
reading/visualizing) depends on this being up first.

## `PersistentVolumeClaim` (`es-data`)

Requests 10Gi, `ReadWriteOnce`. No `storageClassName` is set on purpose - that
makes Kubernetes provision from whichever `StorageClass` is marked as the
*default* on the cluster (on AKS this provisions an Azure Disk, e.g. via
`managed-csi`), so the manifest doesn't hard-code an AKS-specific class name.

**Why this matters**: without a PVC, Elasticsearch's data directory would need
an `emptyDir` volume, which is wiped every time the pod restarts or gets
rescheduled - fine for a 5-minute demo, not for anything you want to keep
querying later. With the PVC, the indexed logs survive pod restarts.

## `Deployment` (`elasticsearch`)

- **`strategy.type: Recreate`** (not the default `RollingUpdate`): with a
  single replica backed by a `ReadWriteOnce` PVC, `RollingUpdate` tries to
  start the new pod (possibly on a different node) *before* the old one
  releases the volume - which can never succeed, since only one pod can hold
  an RWO volume at a time. `Recreate` terminates the old pod first, then
  starts the new one. See the main [README](README.md)'s Troubleshooting
  section for what this looks like when it goes wrong.
- **`env`**:
  - `discovery.type=single-node` - tells Elasticsearch not to wait for other
    cluster nodes to form a quorum (there's only one replica here).
  - `xpack.security.enabled=false` - disables auth/TLS so this stays a
    quick-start/practice stack with no certificate setup. Don't carry this
    setting into anything production-facing.
  - `ES_JAVA_OPTS=-Xms512m -Xmx512m` - fixes the JVM heap size; without this
    Elasticsearch auto-sizes the heap off total node memory, which can
    over-allocate on a shared/small node.
- **`securityContext.fsGroup: 1000`**: Azure Disk volumes are mounted
  root-owned by default; Elasticsearch's container process runs as uid 1000
  (the `elasticsearch` user baked into the image), so without `fsGroup` it
  can't write to its own data directory.
- **`resources.requests.cpu: 400m`**: kept modest (rather than e.g. `1000m`)
  so a small 2-node/2-vCPU-per-node AKS cluster still has enough spare CPU
  *request* headroom left on each node for the Filebeat DaemonSet pod to be
  schedulable there too. See the main README's Troubleshooting section for
  what happens when this isn't left low enough.
- **`readinessProbe`**: hits `/_cluster/health?local=true` on port 9200: the
  pod isn't marked Ready (and won't receive traffic from the `Service`) until
  Elasticsearch itself reports healthy, not just until the container process
  has started.
- **`volumeMounts`**: mounts the `es-data` PVC at
  `/usr/share/elasticsearch/data`, the image's data directory.

## `Service` (`elasticsearch`)

Default `ClusterIP` type (no `type:` set) - Elasticsearch is only ever talked
to from inside the cluster (by Logstash, and by Kibana), so it doesn't need a
public IP. Exposes:
- `9200` (`http`) - the REST API Logstash/Kibana/`curl` use.
- `9300` (`transport`) - inter-node cluster communication; unused with a
  single node, but defined for consistency/future multi-node setups.

Other manifests reach this at `http://elasticsearch:9200` (same-namespace
short DNS name) or the fully-qualified
`elasticsearch.logging.svc.cluster.local:9200`.
