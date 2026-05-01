"""Public API for rules_mimir."""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")

# Mimir's core data-path components (replica=1 each in the smoke render).
# Names follow `<release>-<component>` — release name pinned to `mimir`
# at maintainer-render time. The 5 stateless Deployments handle ingest
# (distributor), query (querier + query-frontend + query-scheduler), and
# the public-facing nginx (gateway). query-scheduler became mandatory
# in Mimir 3.x — `frontend_worker.frontend_address` was removed in
# favor of always-via-scheduler.
_MIMIR_DEPLOYS = [
    "mimir-distributor",
    "mimir-querier",
    "mimir-query-frontend",
    "mimir-query-scheduler",
    "mimir-gateway",
]
# 3 StatefulSets — ingester (write path), compactor (block compaction),
# store-gateway (read path for old blocks). All on the data path; missing
# any means push or query will fail in unobvious ways.
#
# Note: when zoneAwareReplication is OFF (smoke render), the StatefulSets
# render as plain `mimir-ingester` / `mimir-store-gateway`. With zone-
# awareness ON, the chart instead emits `mimir-ingester-zone-{a,b,c}` —
# v0.1's pinned manifest uses the single-zone shape.
_MIMIR_ROLLOUTS = [
    "sts/mimir-ingester",
    "sts/mimir-compactor",
    "sts/mimir-store-gateway",
]
_MIMIR_CRD = ""  # Mimir doesn't ship CRDs

def mimir_install(
        name,
        namespace = "mimir",
        wait_timeout = "600s",
        **kwargs):
    """Apply the pinned Mimir manifest into `namespace` and block until
    the 4 Deployments + 3 StatefulSets are ready before idling.

    Drops into `itest_service.exe`. Wait timeout 600s — Mimir pulls the
    `grafana/mimir` image once across all components (~150MB), but
    cluster-pull deduplication is per-node so kind's single-node setup
    only pulls once total.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply(
        name = name,
        manifests = ["@rules_mimir//private/manifests:mimir.yaml"],
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_deployments = list(_MIMIR_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_MIMIR_ROLLOUTS) + list(extra_rollouts),
        wait_timeout = wait_timeout,
        **kwargs
    )

def mimir_health_check(
        name,
        namespace = "mimir",
        **kwargs):
    """Readiness probe paired with `mimir_install`."""
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(_MIMIR_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_MIMIR_ROLLOUTS) + list(extra_rollouts),
        **kwargs
    )
