#!/usr/bin/env bash
# Image round-trip smoke. Pushes a synthetic OCI image to Harbor via
# `crane append`, pulls it back via `crane export`, asserts the layer
# payload comes back byte-for-byte. Proves Harbor's HTTP API + auth +
# registry-backend storage all work end-to-end.
#
# Strategy: a single in-cluster `kubectl run` with the
# `gcr.io/go-containerregistry/crane:debug` image (busybox-shelled,
# unlike `:latest` which is bare distroless). The inline script runs
# the full assertion and exits; `kubectl run --rm --attach` blocks for
# its exit code and streams its stdout. No long-lived "keep-alive" pod
# needed.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="${HARBOR_SMOKE_NS:-default}"
PAYLOAD="rules_harbor-smoke-$RANDOM-$(date +%s)"
TAG="smoke-${PAYLOAD//[^A-Za-z0-9._-]/_}"

# Inline script. Single-quoted heredoc preserves $VAR escapes — the
# variables resolve inside the pod shell, not on the test driver.
# Values are passed in via --env below.
read -r -d '' SCRIPT <<'CRANE_EOF' || true
set -e
export HOME=/tmp
HOST="harbor.harbor.svc"

echo "[crane] preparing 1-layer tarball (payload=$PAYLOAD)"
mkdir -p /tmp/work/data
printf '%s\n' "$PAYLOAD" > /tmp/work/data/payload.txt
tar -cf /tmp/work/layer.tar -C /tmp/work data

# Harbor's Deployments going Available != "registry HTTP path is wired."
# nginx-front + core boot in different orders; the registry endpoint
# can 502 for a few seconds after the Deployment readiness gate. Poll
# /api/v2.0/health for the canonical "healthy" before pushing.
echo "[crane] waiting for ${HOST}/api/v2.0/health"
i=0
while [ $i -lt 60 ]; do
  if wget -qO- "http://${HOST}/api/v2.0/health" 2>/dev/null | grep -q '"status":"healthy"'; then
    echo "[crane]   harbor health: ok"
    break
  fi
  sleep 3
  i=$((i + 1))
done
wget -qO- "http://${HOST}/api/v2.0/health" 2>/dev/null | grep -q '"status":"healthy"' \
  || { echo "FAIL: /api/v2.0/health never reported healthy" >&2; exit 1; }

echo "[crane] auth login as admin"
crane auth login "${HOST}" -u admin -p Harbor12345

echo "[crane] append --new_tag ${HOST}/library/smoke:${TAG}  (push)"
crane append \
  --new_layer /tmp/work/layer.tar \
  --new_tag "${HOST}/library/smoke:${TAG}" \
  --insecure

echo "[crane] export ${HOST}/library/smoke:${TAG}  (pull)"
crane export "${HOST}/library/smoke:${TAG}" - --insecure \
  | tar -xO data/payload.txt > /tmp/got.txt

GOT="$(cat /tmp/got.txt)"
if [ "$GOT" = "$PAYLOAD" ]; then
  echo "SMOKE_OK — payload round-tripped through Harbor"
else
  echo "SMOKE_FAIL got='$GOT' expected='$PAYLOAD'" >&2
  exit 1
fi
CRANE_EOF

echo "smoke_test: launching crane:debug pod (single-shot)"
"${KCTL[@]}" -n "$NS" run --rm -i harbor-crane \
    --image=gcr.io/go-containerregistry/crane:debug \
    --restart=Never \
    --env="PAYLOAD=$PAYLOAD" \
    --env="TAG=$TAG" \
    --command -- /busybox/sh -c "$SCRIPT"
