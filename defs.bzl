"""Public API for rules_harbor.

Two macros wrapping rules_kubectl's `kubectl_apply` /
`kubectl_apply_health_check` with Harbor-specific defaults: namespace,
the committed pre-rendered manifest, and the right wait shape (4
stateless Deployments + 2 stateful StatefulSets).
"""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")

# Component names from the rendered manifest. The chart names everything
# after the release name, which we pin to `harbor` at maintainer-render
# time. With `expose.type=clusterIP`, the chart adds an `harbor-nginx`
# Deployment that reverse-proxies between the core API + portal UI;
# clients hit Service `harbor` (port 80), which routes through nginx.
# Other components (trivy, exporter) are disabled in the values; if a
# consumer re-renders with them on, they'd extend `wait_for_*`.
_HARBOR_DEPLOYS = [
    "harbor-nginx",       # user-facing reverse proxy (Service: harbor:80)
    "harbor-core",
    "harbor-portal",
    "harbor-jobservice",
    "harbor-registry",
]
_HARBOR_ROLLOUTS = [
    "sts/harbor-database",
    "sts/harbor-redis",
]

def harbor_install(
        name,
        namespace = "harbor",
        wait_timeout = "600s",
        **kwargs):
    """Apply the pinned Harbor manifest into `namespace` and block until
    Harbor's stateless Deployments + stateful StatefulSets are ready.

    Drops into `itest_service.exe`. Wait timeout defaults to 600s — Harbor
    pulls ~6 container images on first start.

    Args:
      name: target name.
      namespace: target namespace. Pre-created idempotently. Default `harbor`.
      wait_timeout: per-wait timeout. Default 600s for image pulls.
      **kwargs: forwarded to `kubectl_apply`.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply(
        name = name,
        manifests = ["@rules_harbor//private/manifests:harbor.yaml"],
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_deployments = list(_HARBOR_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_HARBOR_ROLLOUTS) + list(extra_rollouts),
        wait_timeout = wait_timeout,
        **kwargs
    )

def harbor_health_check(
        name,
        namespace = "harbor",
        **kwargs):
    """Readiness probe paired with `harbor_install`. Drops into
    `itest_service.health_check`."""
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(_HARBOR_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_HARBOR_ROLLOUTS) + list(extra_rollouts),
        **kwargs
    )
