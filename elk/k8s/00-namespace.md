# `00-namespace.yaml`

**Resources defined:** 1x `Namespace`

## Purpose

Creates the `logging` namespace that every other manifest in this folder
deploys into. Applied first (hence the `00-` prefix) because Kubernetes
rejects creating objects in a namespace that doesn't exist yet.

## Why a dedicated namespace

- **Isolation**: the ELK stack's `Deployment`/`Service`/`ConfigMap` names
  (`elasticsearch`, `logstash`, `kibana`) are generic and would collide with
  similarly-named objects in other namespaces (e.g. `default`) if not scoped.
- **RBAC boundary**: Filebeat's `ServiceAccount` is bound to this namespace
  (see `40-filebeat.yaml`), scoping where its credentials "live" even though
  its `ClusterRole` grants cluster-wide read access for log metadata.
- **One-shot teardown**: `kubectl delete namespace logging` (or
  `kubectl delete -f 00-namespace.yaml`) removes every object created in it,
  including the `es-data` `PersistentVolumeClaim` and its backing Azure Disk -
  useful for a clean reset, but also why the main [README](README.md)
  warns to only delete it once you no longer need the indexed logs.

## Dependents

Every other manifest in this folder (`10-elasticsearch.yaml` through
`40-filebeat.yaml`) sets `metadata.namespace: logging` and depends on this
one being applied first:

```powershell
kubectl apply -f 00-namespace.yaml
```
