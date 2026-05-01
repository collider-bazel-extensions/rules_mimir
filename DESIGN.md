# rules_mimir — design decisions

Hermetic [Grafana Mimir](https://grafana.com/oss/mimir/) install for Bazel
test compositions. Same shape as `rules_loki` / `rules_grafana` /
`rules_harbor` / `rules_external_secrets` — pure glue over `rules_kubectl`
+ `rules_helm`.

## Decided

| # | Decision | Choice | Source |
|---|---|---|---|
| 1 | Bzlmod / WORKSPACE | **Bzlmod-only at v0.1.** | Sibling-family |
| 2 | Module / repo name | `rules_mimir`. | Convention |
| 3 | Architecture | **Layered.** Two macros wrapping `kubectl_apply` / `kubectl_apply_health_check`. | rules_loki / rules_grafana / rules_harbor / rules_external_secrets |
| 4 | Manifest provisioning | `mimir-distributed` helm chart **pre-rendered** into `private/manifests/mimir.yaml` via `rules_helm`. Committed. | rules_loki pattern |
| 5 | Single-version | One pinned chart (`6.0.6`, Mimir app `3.0.4`). Multi-version is the rules_cloudnativepg pattern; add it if a real consumer wants two versions side-by-side. | Pragmatic |
| 6 | Render mode | **Smoke fixture.** All replicas=1, filesystem storage, multitenancy off, alertmanager + ruler off, all caches off, query-scheduler on, chart-bundled `mimir-kafka` StatefulSet off, all other subcharts (minio, grafana-agent-operator, rollout-operator) off. The smoke instead points Mimir's `ingest_storage.kafka.address` at an external Kafka supplied by `rules_kafka`. README warns the values are not a production starting point. | Smoke pragmatic |
| 7 | Public surface | `mimir_install`, `mimir_health_check`. **No `mimir_tenant` rule** — tenants are HTTP headers (`X-Scope-OrgID`), not k8s objects; consumers control them at request time. | Smaller surface |
| 8 | Namespace | `mimir` (default, idempotent create). | Convention |
| 9 | Wait shape | 5 Deployments (`mimir-distributor`, `mimir-querier`, `mimir-query-frontend`, `mimir-query-scheduler`, `mimir-gateway`) + 3 StatefulSets (`mimir-ingester`, `mimir-compactor`, `mimir-store-gateway`). All on the data path; missing any means push or query fails in unobvious ways. No CRDs (Mimir doesn't ship any). | Mimir-specific |
| 10 | Smoke data source | **Prometheus pod inside the cluster, configured with `remote_write -> mimir-gateway`.** Prometheus scrapes itself and pushes its own metrics into Mimir. | See "Why Prometheus, not curl" below |
| 11 | Smoke assertion | Cross-rule composition: rules_kafka stands up a single-broker KRaft Kafka; Mimir's distributor produces records to that Kafka cluster; ingester consumes from the same topic; querier serves them. Apply Prometheus + ConfigMap. Wait for the pod Ready. Poll Mimir's `/prometheus/api/v1/query?query=prometheus_build_info` until it returns a non-empty result vector. Then assert the Kafka topic `mimir-ingest` was auto-created by Mimir's distributor — that's the "Kafka was actually in the loop" check. Proves the full Kafka-backed write path — **not** "Mimir pods are up." | Per the family's "exercise the functionality" rule |
| 12 | Cross-rule deps | `rules_kubectl` public dep. `rules_helm` + `rules_kind` + `rules_itest` + `rules_shell` + **`rules_kafka`** dev-only. No cert-manager required (Mimir has no admission webhooks). The rules_kafka dep is dev-only because v0.1 consumers can pick any Kafka — they just override `mimir.structuredConfig.ingest_storage.kafka.address`. | rules_loki + rules_cloudnativepg/rules_certmanager compose pattern |
| 13 | Naming | snake_case rules/macros, `MixedCaseInfo` providers (none in v0.1), `UPPER_SNAKE` constants. | All siblings |
| 14 | Update workflow | `bash tools/render_mimir.sh <chart-version>` → thin shim. | rules_loki precedent |

## Mimir-specific notes

### Why Prometheus, not curl

The smoke's data source is a Prometheus pod inside the cluster doing
`remote_write` to Mimir's gateway. The gateway routes the write to
the distributor, the distributor produces records to Kafka (the
external `rules_kafka` cluster), the ingester consumes from the same
topic, and the querier serves the result back via PromQL. Prometheus
acts as the protobuf encoder so we don't have to.

Prometheus's `remote_write` protocol is Snappy-compressed protobuf —
specifically `prometheus.WriteRequest` from `prompb/types.proto`. Producing
a valid request from a shell would mean either (a) baking a Go/Python
binary into the test that emits the protobuf, or (b) checking in a
pre-encoded fixture, both of which trade hermeticity for opacity. Running
Prometheus itself as the test driver keeps the smoke faithful to a real
consumer (Mimir's #1 ingestion source) without an extra moving part. The
prom/prometheus image is small (~250MB compressed) and Prometheus reaches
its first scrape+push cycle within ~10s.

(Side note: an even more direct smoke would be to publish the encoded
record straight to the Kafka `mimir-ingest` topic, bypassing the
distributor. Mimir uses an internal `WriteRequest` protobuf shape on
that topic — distinct from Prometheus's `remote_write` envelope — so
the exercise of constructing valid bytes from shell would be even
worse there. The current shape exercises the full distributor → Kafka
→ ingester path, which is what consumers actually deploy.)

Alternatives considered:
- **OTLP / `POST /otlp/v1/metrics`.** OTLP-HTTP can take JSON, so a curl
  push is feasible. But OTLP/JSON for metrics is verbose to construct
  (`ResourceMetrics` → `ScopeMetrics` → `Metric` → `Sum` → `NumberDataPoint`),
  and it doesn't exercise the busiest write path in real Mimir deployments.
- **InfluxDB line-protocol push.** Mimir supports `/api/v1/push/influx/write`
  as plain text, but it's gated on `-distributor.influx-write-enabled`
  (off by default). Would mean adding a non-default config flag just for
  the smoke.

### Disabled chart components — why

The chart renders ~30 templates; v0.1's smoke fixture turns most off.
Reasons:

- **`alertmanager` / `ruler`** — non-default code paths; each adds another
  StatefulSet on the data path. Smoke focuses on read+write; alerting + recording
  rules are deferred to v0.2 with a real assertion (route an alert / fire a rule).
- **`*-cache` (chunks/index/metadata/results)** — memcached pods. Nice for
  prod query latency; meaningless at smoke scale (single ingester, fresh
  data, no compacted blocks).
- **chart-bundled `kafka`** — the chart will render its own `mimir-kafka`
  StatefulSet by default (`kafka.enabled: true` in chart values.yaml).
  We turn that off (`kafka.enabled: false`) and instead point Mimir's
  `ingest_storage.kafka.address` at an *external* Kafka supplied by
  `rules_kafka` in the smoke composition. Two reasons: (a) `rules_kafka`
  is the family's blessed Kafka rule set, so composing it here is
  consistent with how cross-rule smokes work elsewhere
  (rules_cloudnativepg + rules_certmanager); (b) the chart-bundled
  Kafka doesn't expose KRaft 4.x knobs we need (single-broker
  replication-factor overrides), and `rules_kafka` already solves
  those.
- **`minio` subchart** — chart's bundled S3-compatible object store, used
  when `common.storage.backend = s3`. Filesystem backend means we don't
  need it.
- **`rollout-operator` subchart** — coordinates rolling restarts of the
  StatefulSets. Single-replica means no coordination needed.
- **`grafana-agent-operator` subchart (`metaMonitoring.grafanaAgent`)** —
  scrapes Mimir's own metrics + ships them upstream. Observability sugar
  unrelated to the smoke.
- **`zoneAwareReplication.enabled: false`** on ingester + store-gateway —
  prod-shape would render `mimir-ingester-zone-{a,b,c}` StatefulSets and
  require 3 replicas per zone. Smoke uses the single-zone shape; the
  StatefulSets render as plain `mimir-ingester` / `mimir-store-gateway`.
- **`*.persistentVolume.enabled: false`** — emptyDir for ingester /
  compactor / store-gateway. Smoke is ephemeral by design.

### Multitenancy

`mimir.structuredConfig.multitenancy_enabled: false` — requests don't
need an `X-Scope-OrgID` header. The gateway's nginx defaults missing
headers to `anonymous`, and Mimir itself accepts the `anonymous` tenant
when multitenancy is off. Production deployments invert this.

### Gateway nginx routing (port 8080 → service port 80)

The chart's gateway is an nginx pod with a hand-written ConfigMap that
proxies path prefixes to the right backend service:

| Prefix | Target |
|---|---|
| `/api/v1/push`, `/otlp/v1/metrics`, `/distributor` | `mimir-distributor-headless:8080` |
| `/prometheus/...` (after rule routing) | `mimir-query-frontend:8080` |
| `/prometheus/api/v1/rules`, `/prometheus/config/v1/rules` | `mimir-ruler:8080` |
| `/alertmanager`, `/api/v1/alerts` | `mimir-alertmanager-headless:8080` |
| `/api/v1/upload/block/` | `mimir-compactor:8080` |
| `/api/v1/status/buildinfo` | `mimir-query-frontend:8080` |

Disabling alertmanager + ruler leaves their nginx routes pointing at
non-existent backends — harmless because we never hit them in the smoke.

## v0.1.0 status

| Area | State |
|---|---|
| MODULE.bazel (Bzlmod-only) | done |
| `mimir_install` + `mimir_health_check` macros | done |
| Pinned `mimir-distributed` chart 6.0.6 (rendered + committed) | done |
| `config/mimir-values.yaml` (exported) | done |
| Maintainer render flow (`bash tools/render_mimir.sh <ver>`) | done |
| Analysis test | done |
| Smoke (kind + Mimir + Prometheus remote_write + PromQL round-trip) | done |
| `examples/` (Prometheus remote_write, OTLP sketch) | done |

## Deferred (not v0.1.0)

- **OTLP smoke** — compose with an OpenTelemetry Collector pod that
  scrapes Prometheus-style endpoints + pushes via OTLP. Different write
  code path than remote_write.
- **Multi-tenant smoke** — flip `multitenancy_enabled = true`; push +
  query under two tenants; assert isolation.
- **Object-storage backend smoke** — compose with a `minio` or
  `rules_minio` fixture; switch storage backend to s3; verify blocks land
  + are queryable through store-gateway.
- **Alertmanager smoke** — turn alertmanager back on; push an alert via
  the gateway; assert it appears in `/alertmanager/api/v2/alerts`.
- **Ruler smoke** — define a recording rule via `/prometheus/config/v1/rules`;
  push samples; query the recorded series back.
- **HA smoke** — 3-replica ingesters with `zoneAwareReplication.enabled: true`;
  fault-inject one zone; assert reads still serve.
- **Multi-version chart support** — single pin in v0.1.
- **Production-grade values file** — explicit consumer responsibility; this
  rule set ships a smoke-fixture render, not a prod baseline.
