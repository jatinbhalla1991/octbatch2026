# `logstash.conf`

## Purpose

This is the Logstash pipeline used by the **local Docker Compose** stack
(`elk/docker-compose.yaml`) - the standalone-file equivalent of the
`logstash-pipeline` `ConfigMap` baked into
[`../../k8s/20-logstash.yaml`](../../k8s/20-logstash.yaml) for the AKS
deployment. See [`../../k8s/20-logstash.md`](../../k8s/20-logstash.md) for a
line-by-line explanation of the shared concepts (grok parsing, ECS field
names); this file only covers how/why the **Docker Compose version differs**.

In `docker-compose.yaml`, this file is bind-mounted read-only into the
Logstash container:
```yaml
volumes:
  - ./logstash/pipeline:/usr/share/logstash/pipeline:ro
```

## How it differs from the Kubernetes version

| | This file (Docker Compose) | `k8s/20-logstash.yaml` (AKS) |
|---|---|---|
| Delivery | Bind-mounted file on the Docker host | Inline text in a `ConfigMap`, mounted as a volume |
| Log source metadata | Filebeat's **Docker** autodiscover (`add_docker_metadata`) | Filebeat's **Kubernetes** autodiscover (`add_kubernetes_metadata`) |
| Filter condition field | `[container][name]` | `[kubernetes][namespace]` / `[kubernetes][container][name]` |
| Output index | Single `docker-logs-*` | Split `k8s-logs-*` / `k8s-system-logs-*` by `log_type` |

The filter condition here is `if [container][name] =~ "web"` - it matches
using a regex (`=~`) against the Docker container's *name*, because the local
stack's [`docker/docker-compose.yaml`](../../../docker/docker-compose.yaml)
names the nginx service's container `web` (vs. the Kubernetes Deployment's
pod/container both being named `sample` - see `docker/menifest.yaml`). The
`[container][name]` field itself comes from Filebeat's `add_docker_metadata`
processor (see [`../../filebeat/filebeat.yml`](../../filebeat/filebeat.yml)),
which is the Docker-autodiscover equivalent of
`add_kubernetes_metadata`.

There's no `log_type`-based output split here because there's no "node
system logs vs. container logs" distinction to make on a single Docker host
the way there is across multiple Kubernetes nodes - every container's logs
go to the one `docker-logs-%{+YYYY.MM.dd}` index.

## Block-by-block

```
input {
  beats {
    port => 5044
  }
}
```
Listens for Beats-protocol connections on `5044` - this is what
[`../../filebeat/filebeat.yml`](../../filebeat/filebeat.yml)'s
`output.logstash.hosts: ["logstash:5044"]` connects to.

```
filter {
  if [container][name] =~ "web" {
    grok { match => { "message" => "%{COMBINEDAPACHELOG}" } }
    date { match => ["timestamp", "dd/MMM/yyyy:HH:mm:ss Z"]; remove_field => ["timestamp"] }
  }
}
```
Only the `web` (nginx) container's log lines get grok-parsed into structured
fields (ECS-compatible field names, e.g. `http.response.status_code` - see
`k8s/20-logstash.md` for the full field list); everything else (the `backend`
Redis container, the `db` Postgres container) passes through as a raw
`message` field, unparsed.

```
output {
  elasticsearch {
    hosts => ["http://elasticsearch:9200"]
    index => "docker-logs-%{+YYYY.MM.dd}"
  }
}
```
Writes every event to a single, date-rolled index,
`docker-logs-YYYY.MM.DD`. In Kibana, create a data view for `docker-logs-*`
(see the main [README](../../README.md)'s "Local (Docker Compose)" section)
to browse these.
