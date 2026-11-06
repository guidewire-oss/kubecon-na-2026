#!/usr/bin/env bash
# KubeVela 1.12 demo: Setup
# Creates a k3d cluster, installs vela-core 1.12.0-alpha.1 with every gate the demos use,
# then the prerelease VelaUX, and creates its admin user.
#
# Needs: docker, k3d, helm, kubectl, curl, and the vela CLI 1.12.0-alpha.1:
#   curl -fsSl https://kubevela.io/script/install.sh | bash -s 1.12.0-alpha.1
#
#   ./00-setup.sh            set everything up (CLUSTER, ADMIN_PASSWORD and UX_PORT override the defaults)
#   ./00-setup.sh --zscaler  trust REGISTRY_CA_BUNDLE or ~/zscaler/zscaler_root.crt
#   ./00-setup.sh --cleanup  delete the cluster
set -euo pipefail

CLUSTER=${CLUSTER:-kubecon}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-KubeCon2026}
UX_PORT=${UX_PORT:-8000}
VERSION=1.12.0-alpha.1
REGISTRY_CA_BUNDLE=${REGISTRY_CA_BUNDLE:-}
# containerd's Go TLS stack reads every file in /etc/ssl/certs.
NODE_CA_PATH=/etc/ssl/certs/registry-ca.crt

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for arg in "$@"; do
  case "$arg" in
    --zscaler) REGISTRY_CA_BUNDLE=${REGISTRY_CA_BUNDLE:-$HOME/zscaler/zscaler_root.crt} ;;
    --cleanup) k3d cluster delete "$CLUSTER"; exit 0 ;;
    *) fail "Unknown option: $arg" ;;
  esac
done

for tool in docker k3d helm kubectl curl vela; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done
if [ -n "$REGISTRY_CA_BUNDLE" ] && [ ! -f "$REGISTRY_CA_BUNDLE" ]; then
  fail "REGISTRY_CA_BUNDLE $REGISTRY_CA_BUNDLE is not a file"
fi
vela version 2>/dev/null | grep -q "$VERSION" || fail "vela CLI is not $VERSION; install it with: curl -fsSl https://kubevela.io/script/install.sh | bash -s $VERSION"

step "Create the k3d cluster $CLUSTER (your default kubeconfig is left alone)"
if k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  # k3d cannot add a volume to an existing cluster.
  if [ -n "$REGISTRY_CA_BUNDLE" ]; then
    docker exec "k3d-$CLUSTER-server-0" test -f "$NODE_CA_PATH" 2>/dev/null || \
      fail "$CLUSTER was created without the CA; run ./00-setup.sh --cleanup and retry"
  fi
else
  volume=""
  if [ -n "$REGISTRY_CA_BUNDLE" ]; then
    volume="--volume=$REGISTRY_CA_BUNDLE:$NODE_CA_PATH:ro@server:*;agent:*"
  fi
  # Avoid empty arrays: macOS bash 3.2 fails on them under set -u.
  k3d cluster create "$CLUSTER" --kubeconfig-update-default=false --wait ${volume:+"$volume"}
fi
KUBECONFIG=$(k3d kubeconfig write "$CLUSTER")
export KUBECONFIG

step "Install vela-core $VERSION with the demo gates"
helm repo add kubevela https://kubevela.github.io/charts >/dev/null 2>&1 || true
helm repo update kubevela >/dev/null
helm upgrade --install kubevela kubevela/vela-core -n vela-system --create-namespace \
  --version "$VERSION" --devel --wait=legacy --timeout 10m \
  --set featureGates.enableCelExpressions=true \
  --set featureGates.enableAddonComponent=true \
  --set featureGates.enableSourceAutoUpdate=true \
  --set featureGates.enableDefinitionInheritance=true

step "Check the controller has the gates"
args=$(kubectl get deploy kubevela-vela-core -n vela-system -o jsonpath='{.spec.template.spec.containers[0].args}')
for g in EnableCelExpressions EnableAddonComponent EnableSourceAutoUpdate EnableDefinitionInheritance; do
  echo "$args" | grep -q "$g=true" || fail "$g is not on"
  echo "ok: $g=true"
done

step "Install the prerelease VelaUX from the experimental registry"
vela addon registry list | grep -q '^experimental' || \
  vela addon registry add experimental --type=helm --endpoint=https://kubevela.github.io/catalog/experimental
# a prerelease version has to be named; the CLI only picks stable versions by itself
vela addon enable velaux-prerelease --version "v$VERSION"
if [ -n "$REGISTRY_CA_BUNDLE" ]; then
  step "Trust the proxy CA in VelaUX for addon catalog downloads"
  kubectl -n vela-system create configmap registry-ca-bundle \
    --from-file=ca-bundle.crt="$REGISTRY_CA_BUNDLE" --dry-run=client -o yaml | kubectl apply -f -
  app=application/addon-velaux-prerelease
  i=0
  found=false
  for name in $(kubectl -n vela-system get "$app" -o jsonpath='{.spec.components[*].name}'); do
    if [ "$name" = velaux-server ]; then found=true; break; fi
    i=$((i + 1))
  done
  [ "$found" = true ] || fail "velaux-server component not found in $app"
  # Re-enabling the addon drops this trait; restore it on each setup run.
  if ! kubectl -n vela-system get "$app" -o jsonpath="{.spec.components[$i].traits[*].type}" | grep -qw storage; then
    kubectl -n vela-system patch "$app" --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/components/$i/traits/-\",
      \"value\":{\"type\":\"storage\",\"properties\":{\"configMap\":[{\"name\":\"registry-ca-bundle\",
      \"mountOnly\":true,\"mountPath\":\"$NODE_CA_PATH\",\"subPath\":\"ca-bundle.crt\",\"readOnly\":true}]}}}]"
    kubectl -n vela-system annotate "$app" --overwrite "app.oam.dev/publishVersion=registry-ca-$(date +%s)"
  fi
  # Wait for reconciliation so rollout status cannot pass on the old pod.
  kubectl -n vela-system wait --for=jsonpath='{.spec.template.spec.volumes[0].configMap.name}'=registry-ca-bundle \
    deploy/velaux-server --timeout=300s
fi
kubectl rollout status deploy/velaux-server -n vela-system --timeout=5m

step "Create the VelaUX admin user"
kubectl port-forward -n vela-system svc/velaux-server "$UX_PORT":8000 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$UX_PORT/" && break; sleep 1; done
configured=$(curl -s "http://127.0.0.1:$UX_PORT/api/v1/auth/admin_configured" | tr -d ' \n')
if echo "$configured" | grep -q '"configured":true'; then
  echo "admin already configured"
else
  curl -sf -X PUT "http://127.0.0.1:$UX_PORT/api/v1/auth/init_admin" -H 'Content-Type: application/json' \
    -d "{\"name\":\"admin\",\"password\":\"$ADMIN_PASSWORD\",\"email\":\"admin@example.com\"}" >/dev/null \
    || fail "could not create the admin user (the password needs letters and digits, 8 to 16 characters)"
  echo "ok: admin user created"
fi

cat <<EOF

PASS: Setup

Point your shell at the cluster:
  export KUBECONFIG=$KUBECONFIG
Open VelaUX (user admin, password $ADMIN_PASSWORD):
  vela port-forward addon-velaux-prerelease -n vela-system $UX_PORT:8000
EOF
