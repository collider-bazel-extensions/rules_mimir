# rules_mimir

Hermetic [Grafana Mimir](https://grafana.com/oss/mimir/) install for Bazel
test compositions. Pure glue layer over
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl) —
`mimir_install` is a macro emitting a `kubectl_apply` target pre-configured
with Mimir's pinned manifest and the right wait shape.

```python
load("@rules_mimir//:defs.bzl", "mimir_install", "mimir_health_check")

mimir_install(name = "mimir_install_bin")          # default ns: mimir
mimir_health_check(name = "mimir_health_bin")
```

That's the whole API. Mimir is a horizontally-scalable Prometheus-compatible
time-series database — ingest via remote_write / OTLP / InfluxDB line protocol,
query via PromQL. This rule set installs the operator (distributor +
ingester + querier + query-frontend + compactor + store-gateway + nginx
gateway) ready for write+query traffic.

**Pinned versions:** `mimir-distributed` helm chart `6.0.6`
(Mimir app `3.0.4`). Smoke-fixture render — single replica per component,
filesystem storage, multitenancy off, alertmanager + ruler off, all
caches off, query-scheduler on, `minio` / `rollout-operator` /
`grafana-agent-operator` subcharts off. The chart-bundled `mimir-kafka`
StatefulSet is also off — the smoke instead points Mimir's
`ingest_storage.kafka.address` at an external Kafka supplied by
[`rules_kafka`](https://github.com/collider-bazel-extensions/rules_kafka).
The values file is exported as `@rules_mimir//config:mimir-values.yaml`
for inspection / extension.

**Supported platforms (v0.1):** any platform where rules_kubectl runs.
Validated on Linux x86\_64 in CI.

---

## Contents

- [Installation](#installation) (Bzlmod-only)
- [Quickstart](#quickstart)
- [Pushing + querying metrics](#pushing--querying-metrics)
- [Macros](#macros)
- [Hermeticity exceptions](#hermeticity-exceptions)
- [Contributing](#contributing)

---

## Installation

```python
bazel_dep(name = "rules_mimir", version = "0.1.0")
```

Bzlmod-only. Transitively pulls in
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl).

---

## Quickstart

```python
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_mimir//:defs.bzl", "mimir_install", "mimir_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# 1. Cluster.
kind_cluster(name = "cluster", k8s_version = "1.32")
kind_health_check(name = "cluster_health", cluster = ":cluster")
itest_service(name = "kind_svc", exe = ":cluster", health_check = ":cluster_health")

# 2. Mimir.
mimir_install(name = "mimir_install_bin")
mimir_health_check(name = "mimir_health_bin")
sh_binary(name = "mimir_install_wrapper", srcs = ["install_wrapper.sh"], data = [":mimir_install_bin"])
sh_binary(name = "mimir_health_wrapper",  srcs = ["health_wrapper.sh"],  data = [":mimir_health_bin"])

itest_service(
    name = "mimir_svc",
    exe = ":mimir_install_wrapper",
    deps = [":kind_svc"],
    health_check = ":mimir_health_wrapper",
)

# 3. Your write/query workload — see `examples/` for shapes.
```

`install_wrapper.sh` / `health_wrapper.sh` are ~20-line shims — see
`tests/install_wrapper.sh` for the canonical shape (sources kind's env
file under `set -a`, exec's the rule binary).

---

## Pushing + querying metrics

Once Mimir is up, the gateway service `mimir-gateway.<namespace>.svc.cluster.local:80`
fronts the read+write paths:

| Path | Routes to | Used for |
|---|---|---|
| `POST /api/v1/push` | distributor | Prometheus remote_write (Snappy-protobuf) |
| `POST /otlp/v1/metrics` | distributor | OTLP HTTP push |
| `GET /prometheus/api/v1/query` | query-frontend | PromQL instant query |
| `GET /prometheus/api/v1/query_range` | query-frontend | PromQL range query |
| `GET /prometheus/api/v1/labels` | query-frontend | label introspection |

Multitenancy is **off** in the smoke render — requests don't need an
`X-Scope-OrgID` header (the gateway nginx defaults missing tenant headers
to `anonymous`). Production deployments override this; supply the header
when you push values to `mimir.structuredConfig.multitenancy_enabled = true`.

The simplest pattern (which `tests/smoke_test.sh` uses): run a Prometheus
pod inside the cluster with `remote_write -> http://mimir-gateway/api/v1/push`,
then query Mimir's PromQL API for one of Prometheus's self-scraped metrics
(e.g. `prometheus_build_info`). See [`examples/prometheus_remote_write.yaml`](examples/prometheus_remote_write.yaml).

---

## Macros

### `mimir_install`

```python
mimir_install(
    name = "mimir_install_bin",
    namespace = "mimir",        # default
    wait_timeout = "600s",      # default
)
```

Expands to a `kubectl_apply(...)` target that:

- Applies `@rules_mimir//private/manifests:mimir.yaml`.
- `create_namespace = True` (default `mimir`).
- `server_side = True`.
- `wait_for_deployments = ["mimir-distributor", "mimir-querier", "mimir-query-frontend", "mimir-query-scheduler", "mimir-gateway"]`.
- `wait_for_rollouts = ["sts/mimir-ingester", "sts/mimir-compactor", "sts/mimir-store-gateway"]`.
- `wait_timeout = "600s"` (Mimir image pulls — `grafana/mimir` is ~150MB).

Drops into `itest_service.exe`.

### `mimir_health_check`

```python
mimir_health_check(name = "mimir_health_bin", namespace = "mimir")
```

Drops into `itest_service.health_check`. Same wait shape with
`--timeout=0s`.

---

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| Mimir manifest | Fully hermetic. URL + sha256 pinned in `tools/versions.bzl`; pre-rendered + committed. | Re-render via `bash tools/render_mimir.sh <ver>`. |
| `kubectl` | Inherited from `rules_kubectl`. | |
| Target cluster | Out of scope. | |
| Mimir container images | Pulled at runtime by the cluster's nodes. | Future: pre-load via `kind_cluster.images`. |

---

## Contributing

PRs welcome. Conventions match the sibling rule sets:

- New rules need an analysis test in `tests/analysis_tests.bzl`.
- Bumping the pinned chart version: edit `tools/versions.bzl`, add a
  `helm_template + sh_binary` block in `tools/BUILD.bazel`, run
  `bash tools/render_mimir.sh <new-version>`, commit.
- `MODULE.bazel.lock` is intentionally not committed.

### Help wanted

- macOS validation
- OTLP push smoke (compose with an OpenTelemetry Collector pod)
- Multi-tenant smoke (turn `multitenancy_enabled` back on; verify per-tenant isolation)
- Object-storage backend smoke (compose with a `minio` or `rules_minio` fixture)
- Alertmanager + ruler smoke (turn the components back on; route an alert)
- HA smoke (3-replica ingesters with `zoneAwareReplication.enabled: true`)
