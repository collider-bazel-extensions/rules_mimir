#!/usr/bin/env bash
# Round-trip a metric through Mimir's *Kafka-backed* ingest path to
# prove the cross-rule composition (rules_kafka + rules_mimir) works
# end-to-end. Strategy:
#
#   1. Apply a tiny Prometheus pod inside the cluster, configured with
#      `remote_write` -> http://mimir-gateway.mimir.svc.cluster.local/api/v1/push.
#      Prometheus scrapes itself (`prometheus_build_info` is a metric
#      it always exposes) and remote-writes the samples to Mimir.
#
#   2. Mimir's distributor — configured via
#      `ingest_storage.kafka.address: kafka.kafka.svc.cluster.local:9092`
#      (mimir-values.yaml) — produces records to the `mimir-ingest`
#      Kafka topic instead of pushing them via gRPC straight to the
#      ingester. The ingester consumes from that same topic and writes
#      to its TSDB.
#
#   3. Spin up a curl pod and poll Mimir's PromQL endpoint
#      /prometheus/api/v1/query?query=prometheus_build_info on the
#      gateway. The metric appears once Prometheus has done a scrape
#      + remote_write cycle and Mimir's distributor -> Kafka ->
#      ingester -> querier path serves it back.
#
#   4. Bonus assertion: kubectl-exec into the Kafka broker and confirm
#      the `mimir-ingest` topic exists. That's the "Kafka was actually
#      in the loop" check — if Mimir wasn't using Kafka the topic
#      wouldn't have been auto-created.
#
# Proves: rules_kafka + rules_mimir composed; Mimir's Kafka ingest
# path (Mimir 3.x's flagship feature, replacing the gRPC push topology)
# fully exercised. Multitenancy is OFF in the smoke render so requests
# don't need an X-Scope-OrgID header.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="smoke"
MIMIR_HOST="mimir-gateway.mimir.svc.cluster.local"
KAFKA_NS="kafka"
KAFKA_POD="kafka-controller-0"
KAFKA_BIN="/opt/bitnami/kafka/bin"
QUERY="prometheus_build_info"
INGEST_TOPIC="mimir-ingest"

echo "smoke_test: applying Prometheus pod with remote_write -> Mimir gateway"
"${KCTL[@]}" apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prom-config
  namespace: ${NS}
data:
  prometheus.yml: |
    global:
      scrape_interval: 5s
    scrape_configs:
      - job_name: self
        static_configs:
          - targets: ['localhost:9090']
    remote_write:
      - url: http://${MIMIR_HOST}/api/v1/push
---
apiVersion: v1
kind: Pod
metadata:
  name: prom
  namespace: ${NS}
  labels:
    app: prom
spec:
  restartPolicy: Never
  containers:
    - name: prom
      image: prom/prometheus:v2.55.1
      args:
        - --config.file=/etc/prom/prometheus.yml
        - --storage.tsdb.path=/prom-data
      ports:
        - name: http
          containerPort: 9090
      readinessProbe:
        httpGet:
          path: /-/ready
          port: 9090
        periodSeconds: 2
      volumeMounts:
        - name: cfg
          mountPath: /etc/prom
        - name: data
          mountPath: /prom-data
  volumes:
    - name: cfg
      configMap:
        name: prom-config
    - name: data
      emptyDir: {}
EOF

echo "smoke_test: waiting for prom pod to be Ready"
"${KCTL[@]}" -n "$NS" wait pod/prom --for=condition=Ready --timeout=120s

echo "smoke_test: launching curl pod"
"${KCTL[@]}" -n "$NS" run mimir-curl --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$NS" delete pod mimir-curl --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/mimir-curl --for=condition=Ready --timeout=60s

# Poll Mimir for the metric. The full pipeline takes a few seconds:
# Prometheus scrape (5s) -> remote_write batch -> Mimir distributor ->
# Kafka append -> ingester consume -> ingester WAL -> queryable.
# Allow up to 180s ceiling — the kafka-ingest path adds an extra hop
# vs. direct gRPC push.
echo "smoke_test: polling Mimir /prometheus/api/v1/query for ${QUERY}"
deadline=$(( $(date +%s) + 180 ))
resp=""
got_data=""
while (( $(date +%s) < deadline )); do
  resp=$("${KCTL[@]}" -n "$NS" exec mimir-curl -- \
      curl -s "http://${MIMIR_HOST}/prometheus/api/v1/query?query=${QUERY}" 2>/dev/null || true)
  # Successful response with data:
  #   {"status":"success","data":{"resultType":"vector","result":[{...}]}}
  # An empty result still has status:success but result:[].
  if grep -q '"status":"success"' <<<"$resp" \
       && grep -q '"result":\[{' <<<"$resp"; then
    got_data="$resp"
    break
  fi
  sleep 3
done

if [[ -z "$got_data" ]]; then
  echo "smoke_test: FAIL — Mimir never returned data for ${QUERY}" >&2
  echo "---- last query response ----" >&2
  echo "$resp" >&2
  echo "---- prom logs (tail) ----" >&2
  "${KCTL[@]}" -n "$NS" logs prom --tail=80 >&2 || true
  echo "---- mimir-distributor logs (tail) ----" >&2
  "${KCTL[@]}" -n mimir logs deploy/mimir-distributor --tail=40 >&2 || true
  echo "---- mimir-ingester logs (tail) ----" >&2
  "${KCTL[@]}" -n mimir logs sts/mimir-ingester --tail=40 >&2 || true
  echo "---- kafka topics ----" >&2
  "${KCTL[@]}" -n "$KAFKA_NS" exec "$KAFKA_POD" -- \
      "$KAFKA_BIN/kafka-topics.sh" --bootstrap-server localhost:9092 --list >&2 || true
  exit 1
fi

# Bonus: confirm Kafka was actually the conduit. Mimir auto-creates
# the `mimir-ingest` topic on first distributor write (chart's
# `auto_create_topic_enabled: true`). If it's not there, Mimir
# wasn't using Kafka — we'd be fooling ourselves into thinking the
# kafka-ingest path was exercised.
echo "smoke_test: confirming Kafka topic '${INGEST_TOPIC}' exists"
TOPICS=$("${KCTL[@]}" -n "$KAFKA_NS" exec "$KAFKA_POD" -- \
    "$KAFKA_BIN/kafka-topics.sh" --bootstrap-server localhost:9092 --list 2>/dev/null \
    | tr -d '\r')
if ! grep -q "^${INGEST_TOPIC}\$" <<<"$TOPICS"; then
  echo "smoke_test: FAIL — Kafka topic '${INGEST_TOPIC}' missing; Mimir's Kafka ingest path didn't fire" >&2
  echo "---- topics actually present ----" >&2
  echo "$TOPICS" >&2
  exit 1
fi

echo "smoke_test: OK — '${QUERY}' round-tripped through Mimir's Kafka-backed ingest path"
echo "smoke_test: OK — '${INGEST_TOPIC}' present on Kafka (rules_kafka), confirming Mimir produced+consumed via Kafka"
