# Pushing + pulling images

Once `harbor_install` is running, the registry is reachable inside the
cluster at the Service `harbor.harbor.svc:80` (port 80, HTTP — see the
TLS section below for production). Default admin credentials are
`admin` / `Harbor12345` until you override `harborAdminPassword` in
your own values render.

The chart auto-creates a public project named `library`; pushes go to
`<host>/library/<repo>:<tag>`.

## In-cluster pod with `crane`

The simplest way to push from within the cluster:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: image-pusher
spec:
  restartPolicy: Never
  containers:
    - name: crane
      image: gcr.io/go-containerregistry/crane:latest
      command: ["sh", "-c"]
      args:
        - |
          set -e
          # Login (HOME must be writable for crane's config.json).
          export HOME=/tmp
          crane auth login harbor.harbor.svc -u admin -p Harbor12345

          # Build a 1-layer image from a tarball and push it.
          mkdir -p /tmp/data && echo "hello from rules_harbor" > /tmp/data/file.txt
          tar -cf /tmp/layer.tar -C /tmp data
          crane append \
            --new_layer /tmp/layer.tar \
            --new_tag harbor.harbor.svc/library/hello:v1 \
            --insecure

          # Pull it back as a flat tarball.
          crane export harbor.harbor.svc/library/hello:v1 - --insecure \
            | tar -xO data/file.txt
```

`tests/smoke_test.sh` is the canonical Bazel-runnable shape — copy from
there if you want to wire image push/pull into your own composition.

## TLS / production exposure

The shipped values render with `expose.type: clusterIP` and
`expose.tls.enabled: false`. Production deployments override:

```yaml
expose:
  type: ingress           # or loadBalancer / nodePort
  tls:
    enabled: true
    certSource: secret    # provide a Secret with tls.crt/tls.key/ca.crt
    secret:
      secretName: harbor-tls
externalURL: https://harbor.example.com
harborAdminPassword: <strong>
```

The chart's `expose.tls.certSource: secret` consumes any TLS Secret —
including one minted by cert-manager (`Certificate` → Secret →
referenced by `secret.secretName`). cert-manager wiring at the chart
layer is documented but not exercised by a v0.1 smoke; raise an issue
if you want it shipped as a dedicated smoke target.

## Robot accounts (production auth)

Admin password works for tests, NOT for production. Real consumers
should mint robot accounts with scoped permissions:

```bash
curl -X POST -H "Content-Type: application/json" \
     -u "admin:$HARBOR_ADMIN_PASS" \
     "https://harbor.example.com/api/v2.0/robots" \
     -d '{
       "name": "ci-pusher",
       "duration": -1,
       "level": "system",
       "permissions": [
         {"kind": "project", "namespace": "library",
          "access": [{"resource": "repository", "action": "push"},
                     {"resource": "repository", "action": "pull"}]}
       ]
     }'
```

Use the returned token as the password in `crane auth login`. v0.1's
smoke uses admin to keep the test compact; consumers wire robot accounts
themselves.
