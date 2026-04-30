# rules_harbor

Hermetic [Harbor](https://goharbor.io/) (OCI registry + UI) install for
Bazel test compositions. Pure glue layer over
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl) —
`harbor_install` is a macro emitting a `kubectl_apply` target
pre-configured with Harbor's pinned manifest and the right wait shape.

```python
load("@rules_harbor//:defs.bzl", "harbor_install", "harbor_health_check")

harbor_install(name = "harbor_install_bin")
harbor_health_check(name = "harbor_health_bin")
```

That's the whole API.

**Pinned versions:** Harbor helm chart `1.18.3` (Harbor app `2.14.3`).
Rendered with `expose.type: clusterIP`, HTTP-only, single-replica
everywhere, no Trivy/Notary/ChartMuseum, emptyDir storage, default
admin password — a **smoke fixture**, not a production starting point.
The values file is exported as `@rules_harbor//config:harbor-values.yaml`
for inspection / extension.

**Supported platforms (v0.1):** any platform where rules_kubectl runs.
Validated on Linux x86\_64 in CI.

---

## Contents

- [Installation](#installation) (Bzlmod-only)
- [Quickstart](#quickstart)
- [Pushing + pulling images](#pushing--pulling-images)
- [Macros](#macros)
- [Production note](#production-note)
- [Hermeticity exceptions](#hermeticity-exceptions)
- [Contributing](#contributing)

---

## Installation

```python
bazel_dep(name = "rules_harbor", version = "0.1.0")
```

Bzlmod-only. Transitively pulls in
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl).

---

## Quickstart

```python
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_harbor//:defs.bzl", "harbor_install", "harbor_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# 1. Cluster.
kind_cluster(name = "cluster", k8s_version = "1.32")
kind_health_check(name = "cluster_health", cluster = ":cluster")
itest_service(name = "kind_svc", exe = ":cluster", health_check = ":cluster_health")

# 2. Harbor — applies the pinned manifest, waits for 5 Deployments + 2 StatefulSets.
harbor_install(name = "harbor_install_bin")
harbor_health_check(name = "harbor_health_bin")

# 3. Wrappers (source the kind env file so KUBECONFIG/KUBECTL cross
#    `exec`). The shape is identical to every other operator rule.
sh_binary(name = "harbor_install_wrapper", srcs = ["install_wrapper.sh"], data = [":harbor_install_bin"])
sh_binary(name = "harbor_health_wrapper",  srcs = ["health_wrapper.sh"],  data = [":harbor_health_bin"])

itest_service(
    name = "harbor_svc",
    exe = ":harbor_install_wrapper",
    deps = [":kind_svc"],
    health_check = ":harbor_health_wrapper",
)
```

---

## Pushing + pulling images

Once the install service is healthy, the registry is reachable in-cluster
at **`harbor.harbor.svc:80`** (HTTP). Default admin login is
`admin` / `Harbor12345`. The chart auto-creates a public project named
`library` — push to `<host>/library/<repo>:<tag>`.

The canonical pattern using the
[`crane`](https://github.com/google/go-containerregistry/tree/main/cmd/crane)
client image:

```bash
# Inside an in-cluster pod with image gcr.io/go-containerregistry/crane:latest:

export HOME=/tmp   # crane writes config to $HOME/.docker/config.json
crane auth login harbor.harbor.svc -u admin -p Harbor12345

# Push a 1-layer image from a tarball.
mkdir -p /tmp/data && echo "hello" > /tmp/data/file.txt
tar -cf /tmp/layer.tar -C /tmp data
crane append \
  --new_layer /tmp/layer.tar \
  --new_tag harbor.harbor.svc/library/hello:v1 \
  --insecure

# Pull it back as a flat tarball.
crane export harbor.harbor.svc/library/hello:v1 - --insecure | tar -xO data/file.txt
```

`tests/smoke_test.sh` is the canonical Bazel-runnable shape — copy from
there to wire image push/pull into your own composition.

See [`examples/push_pull.md`](examples/push_pull.md) for production
notes (TLS via cert-manager, robot accounts).

---

## Macros

### `harbor_install(name, namespace = "harbor", wait_timeout = "600s", **kwargs)`

Expands to a `kubectl_apply(...)` target that:

- Applies `@rules_harbor//private/manifests:harbor.yaml`.
- `create_namespace = True` for `namespace` (default `harbor`).
- `server_side = True`.
- `wait_for_deployments = ["harbor-nginx", "harbor-core", "harbor-portal", "harbor-jobservice", "harbor-registry"]`.
- `wait_for_rollouts = ["sts/harbor-database", "sts/harbor-redis"]`.
- Default `wait_timeout = 600s` (Harbor pulls ~6 container images on first start).

Drops into `itest_service.exe`.

### `harbor_health_check(name, namespace = "harbor", **kwargs)`

Drops into `itest_service.health_check`. Same wait shape with non-blocking
`--timeout=0s`.

---

## Production note

**The shipped values file is a smoke fixture.** It enables:

- `expose.tls.enabled: false` — HTTP only. Anyone reachable to the Service can read/write.
- `harborAdminPassword: Harbor12345` (chart default).
- `persistence.enabled: false` — registry storage in emptyDir, **lost on pod restart**.
- Single-replica everywhere; `trivy.enabled: false`, `exporter.enabled: false`, etc.

For real deployments, **copy `config/harbor-values.yaml` into your own
repo** and override:

- `expose.tls.enabled: true` + `expose.tls.certSource: secret` (with a
  cert-manager-issued Secret, or a manually-managed one)
- `expose.type: ingress` or `loadBalancer`
- `harborAdminPassword: <strong>` (and probably mint robot accounts for
  CI)
- `persistence.enabled: true` + a real StorageClass, or
  `persistence.imageChartStorage.type: s3` (or `gcs` / `azure` / `swift`)
  for object-storage-backed registry
- `replicas` ≥ 2 on stateless components for HA
- `database.type: external` + `redis.type: external` if you're running
  managed Postgres / Redis (e.g. compose with
  [`rules_cloudnativepg`](https://github.com/collider-bazel-extensions/rules_cloudnativepg))

Re-render with your overrides via `rules_helm`'s `helm_template` (the
chart layer is the same; only the values change).

---

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| Harbor manifest | Fully hermetic. URL + sha256 pinned in `tools/versions.bzl`; pre-rendered + committed. | Re-render via `bash tools/render_harbor.sh <ver>`. |
| `kubectl` | Inherited from `rules_kubectl`. | |
| Target cluster | Out of scope. | |
| Harbor container images | Pulled at runtime by the cluster's nodes (~6 images, ~500MB total). | Future: pre-load via `kind_cluster.images`. |
| Smoke-test crane image | `gcr.io/go-containerregistry/crane:latest` pulled at smoke time. | `requires-network`-tagged. |

---

## Contributing

PRs welcome. Conventions match the sibling rule sets:

- New rules need an analysis test in `tests/analysis_tests.bzl`.
- Bumping the pinned chart version: edit `tools/versions.bzl`, add a
  new `helm_template + sh_binary` block in `tools/BUILD.bazel`, run
  `bash tools/render_harbor.sh <new-version>`, commit.
- `MODULE.bazel.lock` is intentionally not committed.

### Help wanted

- macOS validation
- HA-via-`rules_cloudnativepg` smoke variant (external Postgres)
- TLS via cert-manager-issued Secret smoke variant
- Trivy scanner smoke (push image, trigger scan, assert vulnerabilities returned)
- Robot account smoke (push/pull as scoped robot, not admin)
