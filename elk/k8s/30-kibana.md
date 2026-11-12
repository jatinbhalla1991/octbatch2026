# `30-kibana.yaml`

**Resources defined:** 1x `Deployment`, 1x `Service`

## Purpose

Runs Kibana, the browser UI for searching, filtering, live-tailing, and
visualizing everything Logstash has written into Elasticsearch. This is the
only component end users/operators interact with directly - everything else
in this folder exists to get data in front of Kibana.

## `Deployment` (`kibana`)

- `env.ELASTICSEARCH_HOSTS=http://elasticsearch:9200` - points Kibana at the
  in-cluster Elasticsearch `Service` from `10-elasticsearch.yaml` by its
  short DNS name (same namespace, so no need for the fully-qualified
  `elasticsearch.logging.svc.cluster.local`).
- `env.xpack.security.enabled=false` - matches Elasticsearch's setting;
  Kibana would otherwise expect to authenticate against a secured cluster.
  Quick-start/practice setting only - see `10-elasticsearch.md` for the same
  caveat.
- No `strategy`/PVC here, unlike Elasticsearch: Kibana is stateless (its
  "state" - index patterns/data views, saved searches, dashboards - actually
  lives *in* Elasticsearch, not on Kibana's own disk), so the default
  `RollingUpdate` strategy is fine and there's no PVC-deadlock risk like
  `10-elasticsearch.yaml` has.

## `Service` (`kibana`)

- **`type: LoadBalancer`**: provisions an Azure Load Balancer with a public
  IP, mirroring the pattern used by the sample app's `Service` in
  `docker/menifest.yaml` - this is what makes
  `kubectl get svc -n logging kibana` return an `EXTERNAL-IP` you can browse
  to directly, with no `kubectl port-forward`/VPN needed.
- Switch this to `ClusterIP` + `kubectl port-forward -n logging svc/kibana
  5601:5601` instead if you don't want Kibana reachable from the public
  internet.
- Port `5601` is Kibana's default HTTP port, both for the `Service` and the
  container.
