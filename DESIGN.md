# rules_harbor — design decisions

Hermetic [Harbor](https://goharbor.io/) (OCI registry + UI) install for
Bazel test compositions. Same shape as `rules_loki` / `rules_grafana` —
pure glue over `rules_kubectl` + `rules_helm`. ~50 lines of Starlark
glue + a committed pre-rendered manifest.

## Decided

| # | Decision | Choice | Source |
|---|---|---|---|
| 1 | Bzlmod / WORKSPACE | **Bzlmod-only at v0.1.** | Sibling-family |
| 2 | Architecture | **Layered.** Two macros wrapping `kubectl_apply` / `kubectl_apply_health_check`. | rules_loki / rules_grafana |
| 3 | Manifest provisioning | Harbor helm chart **pre-rendered** into `private/manifests/harbor.yaml` via `rules_helm`. Committed. | rules_loki pattern |
| 4 | Single-version | One pinned chart (`1.18.3`, Harbor app `2.14.3`). Multi-version is the rules_cloudnativepg pattern; add it if a real consumer wants two versions side-by-side. | Pragmatic |
| 5 | Render mode | **Smoke-fixture.** `expose.type: clusterIP`, `expose.tls.enabled: false` (HTTP only), `harborAdminPassword: Harbor12345` (chart default), `persistence.enabled: false` (emptyDir), `trivy/notary/chartmuseum/exporter` disabled, single-replica everywhere, internal embedded DB + Redis. README warns loudly that this is NOT a production starting point. | Smoke pragmatic |
| 6 | Public surface | `harbor_install`, `harbor_health_check`. **No `harbor_project` / `harbor_robot` rules.** Consumers author API calls (or YAML for the CRD-based future Harbor operator). | Smaller surface |
| 7 | Namespace | `harbor` (default, idempotent create). | Convention |
| 8 | Wait shape | 5 Deployments + 2 StatefulSets. The 5 Deployments are `harbor-nginx` (the Service-`harbor`-fronting reverse proxy added when `expose.type=clusterIP`), `harbor-core`, `harbor-portal`, `harbor-jobservice`, `harbor-registry`. StatefulSets are `harbor-database` + `harbor-redis`. `wait_for_deployments` + `wait_for_rollouts` cover both. | Harbor-specific |
| 9 | Smoke assertion | **Push + pull a synthetic OCI image via `crane`.** In-cluster pod runs `gcr.io/go-containerregistry/crane:latest`, builds a 1-layer tarball with a unique payload, `crane append`s it to `harbor.harbor.svc/library/smoke:<tag>` (HTTP, `--insecure`), then `crane export`s the image and asserts the layer's payload comes back byte-for-byte. Proves the HTTP API + auth + registry-backend storage all work end-to-end. | Per the family's "exercise the functionality" rule |
| 10 | rules_kubectl dependency | **Public dep.** | Layered architecture |
| 11 | rules_helm dependency | **Dev-only.** Maintainer-side render only. | rules_loki pattern |
| 12 | HA support | **Single-replica in v0.1.** Harbor's HA value mostly lives in the data plane (external DB / Redis / object storage), not in stateless-component replica counts. Multi-replica without fault-injection or external services proves ~nothing the single-replica smoke doesn't. v0.2 candidate: compose with `rules_cloudnativepg` for external Postgres — a meaningful HA smoke. | Pragmatic |
| 13 | TLS / cert-manager smoke | **Deferred.** Harbor's chart-layer TLS is configured via `expose.tls.certSource: secret` (consumes any Secret, including a cert-manager-issued one). v0.1 doesn't ship a smoke variant exercising this; it's a clean follow-up but adds a render variant + a second smoke. | Scope |
| 14 | Trivy scanner smoke | **Deferred.** Trivy adds a separate Deployment + state; smoke would need a triggered scan + result poll. Real but its own scope. | Scope |
| 15 | Naming | snake_case rules/macros, `MixedCaseInfo` providers (none in v0.1), `UPPER_SNAKE` constants. | All siblings |
| 16 | Update workflow | `bash tools/render_harbor.sh <chart-version>` → thin shim. | rules_loki precedent |

## Harbor-specific notes

- The chart's reverse-proxy layer (`harbor-nginx`) is what consumers hit at `Service: harbor:80`. nginx terminates HTTP, matches paths, proxies to `harbor-core` for `/api/*` and `harbor-portal` for everything else. The smoke's host string is `harbor.harbor.svc` (Service name).
- Default admin password `Harbor12345` is the chart default. **Production must override** via `harborAdminPassword` and probably also use external secret management.
- The chart auto-creates a public project named `library`. The smoke pushes to `library/smoke:<tag>` — no "create project" step needed.
- The OCI registry component (`harbor-registry`) is the storage layer. With `persistence.enabled: false`, registry storage is emptyDir — fine for tests, lost on restart.

## v0.1.0 status (planning)

| Area | State |
|---|---|
| MODULE.bazel (Bzlmod-only) | planned |
| `harbor_install` + `harbor_health_check` macros | planned |
| Pinned Harbor chart 1.18.3 (rendered + committed) | planned |
| `config/harbor-values.yaml` (exported) | planned |
| Maintainer render flow | planned |
| Analysis test | planned |
| Smoke (kind + Harbor + crane round-trip) | planned |
| `examples/push_pull.md` (in-cluster crane pattern + production TLS / robot-account notes) | planned |

## Deferred (not v0.1.0)

- **HA via external Postgres** — compose with `rules_cloudnativepg` for the data-plane HA pattern.
- **TLS at the chart layer** — `expose.tls.enabled: true` with cert-manager-issued Secret. v0.2 candidate.
- **Trivy scanner smoke** — push image, trigger scan, assert vulnerabilities returned.
- **Robot account smoke** — POST a robot account, push/pull as that robot, assert scoped permissions.
- **Multi-version chart support** — single pin in v0.1.
- **Replication smoke** — Harbor → Harbor mirroring. Production but heavy.
- **Helm chart hosting smoke** — Harbor hosts helm charts too; orthogonal to OCI registry storage.
