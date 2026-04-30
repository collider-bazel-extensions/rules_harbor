#!/usr/bin/env bash
# Image round-trip smoke. Pushes a synthetic OCI image to Harbor via
# `crane append`, pulls it back via `crane export`, asserts the layer
# payload comes back byte-for-byte. Proves Harbor's HTTP API + auth +
# registry-backend storage all work end-to-end.
#
# Strategy:
#   1. `kubectl run` a pod with `gcr.io/go-containerregistry/crane`.
#   2. From the pod: `crane auth login` against Harbor's user-facing
#      Service (`harbor.harbor.svc:80`), HTTP only — `--insecure`.
#   3. Build a tarball with a unique payload, `crane append --new_tag`
#      to push it as a 1-layer OCI image.
#   4. `crane export` the resulting image's filesystem from Harbor;
#      extract the payload file; assert content matches.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

# Service `harbor` (in ns harbor) routes to harbor-nginx → core/portal/registry.
HARBOR_HOST="harbor.harbor.svc"
NS="${HARBOR_SMOKE_NS:-default}"
PAYLOAD="rules_harbor-smoke-$RANDOM-$(date +%s)"
TAG="smoke-${PAYLOAD//[^A-Za-z0-9._-]/_}"

# crane image — pre-built OCI client. Drops into a kubernetes Pod via
# `kubectl run`. Its ENTRYPOINT runs the `crane` CLI directly, but we
# want a long-running shell in there so we can issue several crane
# subcommands; --command -- tail -f /dev/null keeps it alive.
echo "smoke_test: launching crane pod"
"${KCTL[@]}" -n "$NS" run harbor-crane \
    --restart=Never \
    --image=gcr.io/go-containerregistry/crane:latest \
    --command -- tail -f /dev/null
trap '"${KCTL[@]}" -n "$NS" delete pod harbor-crane --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/harbor-crane --for=condition=Ready --timeout=120s

# Wait for Harbor's HTTP layer to actually serve responses (Deployments
# Ready != "ready to serve" — the reverse-proxy can be Ready before
# core's auth service is alive).
echo "smoke_test: waiting for Harbor /api/v2.0/health"
deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < deadline )); do
  if "${KCTL[@]}" -n "$NS" exec harbor-crane -- \
        wget -qO- "http://${HARBOR_HOST}/api/v2.0/health" 2>/dev/null | grep -q '"status":"healthy"'; then
    break
  fi
  sleep 5
done
if ! "${KCTL[@]}" -n "$NS" exec harbor-crane -- \
        wget -qO- "http://${HARBOR_HOST}/api/v2.0/health" 2>/dev/null | grep -q '"status":"healthy"'; then
  echo "smoke_test: FAIL — Harbor /api/v2.0/health never reported 'healthy'" >&2
  "${KCTL[@]}" -n "$NS" exec harbor-crane -- \
      wget -qO- "http://${HARBOR_HOST}/api/v2.0/health" 2>&1 | head -50 >&2 || true
  exit 1
fi
echo "smoke_test: /api/v2.0/health -> healthy"

# crane stores its config under $HOME/.docker/config.json — set a writable
# HOME so login can persist.
echo "smoke_test: crane auth login"
"${KCTL[@]}" -n "$NS" exec harbor-crane -- sh -c \
  "HOME=/tmp crane auth login ${HARBOR_HOST} -u admin -p Harbor12345"

# Build a tiny tarball with a unique payload. The path inside the tarball
# determines where the file ends up in the image's filesystem at export
# time.
echo "smoke_test: building synthetic 1-layer image (payload=$PAYLOAD)"
"${KCTL[@]}" -n "$NS" exec harbor-crane -- sh -c "
set -e
mkdir -p /tmp/work/data
echo '$PAYLOAD' > /tmp/work/data/payload.txt
tar -cf /tmp/work/layer.tar -C /tmp/work data
"

# Push: crane append takes a base image (or none — produces a 1-layer image)
# + a layer tarball + a tag. The tag is a registry ref, so the resulting
# image is pushed to that ref.
echo "smoke_test: crane append --new_tag ${HARBOR_HOST}/library/smoke:${TAG}"
"${KCTL[@]}" -n "$NS" exec harbor-crane -- sh -c "
set -e
HOME=/tmp crane append \
    --new_layer /tmp/work/layer.tar \
    --new_tag ${HARBOR_HOST}/library/smoke:${TAG} \
    --insecure
"

# Pull back: crane export streams the image's flattened filesystem as a
# tarball. We extract just the payload file and compare to what we sent.
echo "smoke_test: crane export → extract data/payload.txt → compare"
got=$("${KCTL[@]}" -n "$NS" exec harbor-crane -- sh -c "
HOME=/tmp crane export ${HARBOR_HOST}/library/smoke:${TAG} - --insecure \
  | tar -xO data/payload.txt
")

if [[ "$got" != "$PAYLOAD" ]]; then
  echo "smoke_test: FAIL — payload didn't round-trip" >&2
  echo "  expected: '$PAYLOAD'" >&2
  echo "  got:      '$got'" >&2
  echo "---- harbor pods ----" >&2
  "${KCTL[@]}" -n harbor get pods >&2 || true
  exit 1
fi
echo "smoke_test: OK — synthetic image round-tripped through Harbor (push + pull)"
