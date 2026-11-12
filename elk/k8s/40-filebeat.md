# `40-filebeat.yaml`

**Resources defined:** 1x `ServiceAccount`, 1x `ClusterRole`, 1x
`ClusterRoleBinding`, 1x `ConfigMap`, 1x `DaemonSet`

## Purpose

Runs Filebeat, the agent that actually reads logs off each node and ships
them to Logstash. This is the only component deployed as a `DaemonSet`
(one pod per node) rather than a `Deployment` (a fixed number of replicas,
schedulable anywhere) - logs are node-local files, so you need an agent
physically running on *every* node to read all of them, not just some
replicas spread arbitrarily across a subset of nodes.

## RBAC (`ServiceAccount` + `ClusterRole` + `ClusterRoleBinding`)

Filebeat's Kubernetes autodiscover provider needs to look up pod/namespace/
node metadata (labels, owning ReplicaSet, etc.) from the Kubernetes API to
enrich log documents with fields like `kubernetes.namespace` and
`kubernetes.pod.name`. The `ClusterRole` grants exactly `get`/`watch`/`list`
on `namespaces`, `pods`, and `nodes` - read-only, and only those three
resource types (least-privilege: Filebeat never needs to create/modify
anything). The `ClusterRoleBinding` attaches that role to the `filebeat`
`ServiceAccount`, which the `DaemonSet` pods run as
(`serviceAccountName: filebeat`).

A `ClusterRole`/`ClusterRoleBinding` (not a namespaced `Role`/`RoleBinding`)
is required here because Filebeat needs to see pods/namespaces *cluster-wide*
- it ships logs from every namespace, not just `logging`.

## `ConfigMap` (`filebeat-config`)

Mounted into the container as `/etc/filebeat.yml` (the file Filebeat is
launched with via `args: ["-c", "/etc/filebeat.yml", ...]`).

### `filebeat.autodiscover` (container logs, every namespace)

A single `kubernetes` autodiscover provider with **no `condition` key** on
its template. This is deliberate: omitting `condition` makes it the
catch-all/default template, so it ships container logs for *every* pod in
*every* namespace - the sample app as well as cluster system components in
`kube-system` (coredns, metrics-server, azure-cni, konnectivity-agent, etc.).

> An earlier version of this file used `condition: {}` to try to express "no
> filter" - that's actually invalid and crashes Filebeat with
> `missing or invalid condition`. Omitting the key entirely is the correct
> way to get a catch-all template. See the main [README](README.md)'s
> Troubleshooting section.

Each matched container's log file path is
`/var/log/containers/*${data.kubernetes.container.id}.log` - the standard
Kubernetes convention for where the kubelet symlinks container logs on the
node. `fields: { log_type: k8s-container }` with `fields_under_root: true`
stamps a top-level `log_type` field Logstash's `output` block uses to decide
which Elasticsearch index a document goes to (see `20-logstash.md`).

### `filebeat.inputs` (node-level system logs)

Two `journald` inputs, reading each node's systemd journal directly rather
than a container log file - these aren't tied to any pod/namespace, they're
the node's own OS-level logs:
- `include_matches: [_SYSTEMD_UNIT=kubelet.service]` - the kubelet process
  itself (not anything running *in* a pod).
- `include_matches: [_SYSTEMD_UNIT=containerd.service]` - the container
  runtime.

Both stamp `fields: { log_type: node-system, systemd_unit: <name> }`, which
is how Logstash routes these to the separate `k8s-system-logs-*` index
instead of `k8s-logs-*`. Add more `journald` input entries here (with
different `include_matches`) to capture other systemd units.

### `processors`

`add_kubernetes_metadata` - enriches every container-log event with the
pod/namespace/labels metadata looked up via the RBAC permissions above,
matched by the container ID embedded in the `/var/log/containers/` file path.

### `output.logstash`

Ships everything to `logstash.logging.svc.cluster.local:5044` - the
`logstash` `Service`'s fully-qualified DNS name from `20-logstash.yaml`.

## `DaemonSet` (`filebeat`)

- `securityContext.runAsUser: 0` (root): needed to read other containers'
  log files and the host's systemd journal, both of which are normally
  root-owned/root-only on the node.
- `resources.requests.cpu: 100m` - small by design; this needs to fit
  alongside Elasticsearch/Logstash/Kibana on every node, including whichever
  node is already hosting the heavier stateful workloads. See
  `10-elasticsearch.md`/`20-logstash.md` for the other half of this
  CPU-budget story.
- `volumeMounts`/`volumes` (all `hostPath`, i.e. reading directly off the
  node's filesystem):
  - `/var/log/containers`, `/var/log/pods`, `/var/lib/docker/containers` -
    where the kubelet/container runtime write (or symlink to) each
    container's log output.
  - `/var/log/journal`, `/run/log/journal` (`DirectoryOrCreate`) - the
    systemd journal's persistent and volatile storage locations
    respectively; mounting both covers nodes regardless of whether
    persistent journal storage is enabled. `DirectoryOrCreate` means the pod
    still schedules fine even if one of these doesn't exist on a given node
    image (it's created empty rather than failing the mount).
  - `/etc/machine-id` (`File`) - required by the `journald` input to
    correctly identify/read the host's journal.
