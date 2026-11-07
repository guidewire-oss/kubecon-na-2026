#!/usr/bin/env bash
# KubeVela 1.12 demo: Setup
# Every demo in this repo shares one k3d cluster, kubecon, which
# kubevela-bucket-floci-demo/demo.sh creates. If the cluster is missing, this runs
# demo.sh --cluster-only for you (vela-core 1.12.0-alpha.1 with every gate the demos use,
# the prerelease VelaUX and its admin user, Crossplane, ACK, Floci and the bucket
# definitions, but not the product-catalog app). Then it checks the cluster.
#
# Needs: docker, k3d, helm, kubectl, go, and the vela CLI 1.12.0-alpha.1:
#   curl -fsSl https://kubevela.io/script/install.sh | bash -s 1.12.0-alpha.1
#
#   ./00-setup.sh            create the cluster if needed (CLUSTER overrides the name), then check it
#   ./00-setup.sh --zscaler  pass --zscaler to demo.sh: trust REGISTRY_CA_BUNDLE or ~/zscaler/zscaler_root.crt
#   ./00-setup.sh --cleanup  delete the cluster (the bucket demo's clean.sh)
set -euo pipefail

CLUSTER=${CLUSTER:-kubecon}
VERSION=1.12.0-alpha.1
DEMO_DIR=$(cd "$(dirname "$0")/../kubevela-bucket-floci-demo" && pwd)
DEMO_ARGS=()

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for arg in "$@"; do
  case "$arg" in
    --zscaler) DEMO_ARGS+=(--zscaler) ;;
    --cleanup) CLUSTER_NAME=$CLUSTER "$DEMO_DIR/clean.sh"; exit 0 ;;
    *) fail "Unknown option: $arg" ;;
  esac
done

for tool in docker k3d helm kubectl go vela; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done
vela version 2>/dev/null | grep -q "$VERSION" || fail "vela CLI is not $VERSION; install it with: curl -fsSl https://kubevela.io/script/install.sh | bash -s $VERSION"

if k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  step "Use the existing k3d cluster $CLUSTER"
  kubectl config use-context "k3d-$CLUSTER" >/dev/null || fail "k3d-$CLUSTER is not in your kubeconfig; run: k3d kubeconfig merge $CLUSTER --kubeconfig-merge-default"
else
  step "Create the cluster $CLUSTER with demo.sh --cluster-only"
  # ${DEMO_ARGS[@]+...}: an empty array is unbound under set -u on macOS bash 3.2.
  CLUSTER_NAME=$CLUSTER "$DEMO_DIR/demo.sh" --cluster-only ${DEMO_ARGS[@]+"${DEMO_ARGS[@]}"}
fi

step "Check the controller has the gates"
args=$(kubectl get deploy kubevela-vela-core -n vela-system -o jsonpath='{.spec.template.spec.containers[0].args}')
for g in EnableCelExpressions EnableAddonComponent EnableSourceAutoUpdate EnableDefinitionInheritance; do
  echo "$args" | grep -q "$g=true" || fail "$g is not on"
  echo "ok: $g=true"
done

step "Check VelaUX is running"
kubectl rollout status deploy/velaux-server -n vela-system --timeout=5m

cat <<EOF

PASS: Setup

The demos run against the current kubectl context, k3d-$CLUSTER.
Open VelaUX (user admin, password ${VELAUX_ADMIN_PASSWORD:-VelaUX12345}):
  vela port-forward addon-velaux-prerelease -n vela-system 8000:8000
EOF
