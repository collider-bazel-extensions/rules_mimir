# Examples

Reference write/query shapes for Mimir. Apply them after `mimir_install`
has the operator running.

| File | Use case | Exercised by smoke? |
|---|---|---|
| [`prometheus_remote_write.yaml`](prometheus_remote_write.yaml) | Run a Prometheus pod inside the cluster, configured to remote_write to Mimir's gateway. The most common Mimir ingestion source. What `tests/smoke_test.sh` uses. | Yes |
| [`otlp_collector.yaml`](otlp_collector.yaml) | OpenTelemetry Collector with the `prometheusremotewrite` exporter pointed at Mimir. OTLP-style ingestion path. | No (sketch — verified by inspection, not tests, in v0.1) |
| [`promql_query_pod.yaml`](promql_query_pod.yaml) | Curl pod for one-off PromQL queries against `/prometheus/api/v1/query` on the gateway. Useful for ad-hoc inspection during composition development. | Yes (smoke uses the same pattern inline) |

## Multitenancy

The smoke render has `multitenancy_enabled: false`. With that, requests
don't need an `X-Scope-OrgID` header — the gateway nginx defaults missing
headers to `anonymous`. If you flip multitenancy on in your values
override, every push and query must carry the header:

```bash
curl -H 'X-Scope-OrgID: my-tenant' \
     -X POST http://mimir-gateway/api/v1/push --data-binary @body.bin
```

In Prometheus's `remote_write` config, set `headers: {X-Scope-OrgID: my-tenant}`.

## Things this directory deliberately does NOT show

- **Object-storage backends (S3, GCS, Azure Blob).** Each backend has
  its own auth flow + bucket lifecycle. Mimir's `common.storage.backend`
  switches between `filesystem` (smoke), `s3`, `gcs`, `azure`. Production
  consumers handle backend setup outside this rule set.
- **Alertmanager / Ruler.** Disabled in v0.1 smoke render. To enable,
  override `alertmanager.enabled: true` + `ruler.enabled: true` in your
  values file and re-render.
- **Multi-zone HA.** `zoneAwareReplication.enabled: true` on
  ingester / store-gateway renders 3 replicas per zone. Single-zone in v0.1.
