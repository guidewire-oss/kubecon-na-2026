#!/bin/bash
# Same kind cluster as create-kind-cluster.sh (name "substrate", deleted first if
# it exists), then KubeVela 1.12 with the module component enabled, then the
# agent-substrate and kagent MODULES deployed with `vela module deploy`.
#
#   1. ./create-kind-cluster.sh        (recreates the cluster, proxy ARP, kubeconfigs)
#   2. helm install vela-core 1.12.0-alpha.1 with featureGates.enableModuleComponent=true
#   3. a local OCI registry (container "substrate-modules-registry", host port 5001)
#   4. vela module publish + vela module deploy for agent-substrate, then kagent
#
# Usage: ./create-kind-cluster1.12.sh [--zscaler] [--skip-modules]
#   --zscaler       passed to create-kind-cluster.sh (trust the proxy CA)
#   --skip-modules  stop after installing KubeVela
# Env: KIND_CLUSTER_NAME (substrate), VELA_VERSION (v1.12.0-alpha.1),
#      MODULES_DIR (../../catalog/experimental/modules),
#      MODULE_REGISTRY_HOST_PORT (5001),
#      MODULE_REGISTRY_CLUSTER_HOST (host.docker.internal): how vela-core reaches the
#      registry. Both the vela CLI and vela-core read the one registry URL, so it
#      must resolve on the host and in the cluster; Docker and Rancher Desktop
#      provide host.docker.internal for both.
# Needs: docker, kind, kubectl, helm, and a 1.12 `vela` CLI on PATH (the Application
# type: module only exists in 1.12; the 1.11 CLI has no `vela module`).
# Not tested from the dev container (no Docker there). Tear down with ./delete-kind-cluster.sh.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER="${KIND_CLUSTER_NAME:-substrate}"
VELA_VERSION="${VELA_VERSION:-v1.12.0-alpha.1}"
MODULES_DIR="${MODULES_DIR:-$PWD/../../catalog/experimental/modules}"
REG_NAME="substrate-modules-registry"
REG_PORT="${MODULE_REGISTRY_HOST_PORT:-5001}"
REG_CLUSTER_HOST="${MODULE_REGISTRY_CLUSTER_HOST:-host.docker.internal}"
MODULES=(agent-substrate kagent)   # kagent needs agent-substrate first

skip_modules=false
create_args=()
for arg in "$@"; do
    case "$arg" in
        --skip-modules) skip_modules=true ;;
        --zscaler) create_args+=("$arg") ;;
        *) echo "✗ unknown argument $arg" >&2; exit 1 ;;
    esac
done

for tool in docker kind kubectl helm vela; do
    command -v "$tool" >/dev/null || { echo "✗ $tool not found on PATH" >&2; exit 1; }
done
if ! vela module --help >/dev/null 2>&1; then
    echo "✗ this vela CLI has no 'vela module'; install the 1.12 CLI:" >&2
    echo "  curl -fsSl https://kubevela.io/script/install.sh | bash -s $VELA_VERSION" >&2
    exit 1
fi
if [ "$skip_modules" = false ]; then
    for m in "${MODULES[@]}"; do
        [ -f "$MODULES_DIR/$m/_module.cue" ] || { echo "✗ module $m not found in $MODULES_DIR (set MODULES_DIR)" >&2; exit 1; }
    done
fi

# 1. Cluster (same name, deletes an existing one).
KIND_CLUSTER_NAME="$CLUSTER" ./create-kind-cluster.sh ${create_args[@]+"${create_args[@]}"}
export KUBECONFIG="$PWD/substrate.kubeconfig"

# 2. KubeVela 1.12 with the module component. The other gates are the floci demo's.
echo "Installing KubeVela $VELA_VERSION with featureGates.enableModuleComponent=true..."
helm repo add kubevela https://kubevela.github.io/charts >/dev/null 2>&1 || true
helm repo update kubevela >/dev/null
# Helm 4 server-side apply conflicts with vela over the vela-addon-registry ConfigMap.
force_flag=""
helm upgrade --help 2>/dev/null | grep -q -- '--force-conflicts' && force_flag="--force-conflicts"
helm upgrade --install kubevela kubevela/vela-core -n vela-system --create-namespace $force_flag \
    --version "${VELA_VERSION#v}" --devel --wait=legacy --timeout 10m \
    --set featureGates.enableModuleComponent=true \
    --set featureGates.enableCelExpressions=true \
    --set featureGates.enableAddonComponent=true \
    --set featureGates.enableSourceAutoUpdate=true \
    --set featureGates.enableDefinitionInheritance=true

if [ "$skip_modules" = true ]; then
    echo "✓ KubeVela $VELA_VERSION is installed (--skip-modules)."
    exit 0
fi

# 3. Local OCI registry for the modules. It outlives the cluster; publish uses --force.
if ! docker ps --format '{{.Names}}' | grep -qx "$REG_NAME"; then
    docker rm -f "$REG_NAME" >/dev/null 2>&1 || true
    docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --name "$REG_NAME" registry:2 >/dev/null
fi
sleep 2

# 4. Publish and deploy. The registry URL is stored in the cluster, so it uses the
# name vela-core can resolve; publishing goes straight to localhost.
for m in "${MODULES[@]}"; do
    echo "Publishing module $m..."
    vela module publish "$MODULES_DIR/$m" "http://localhost:${REG_PORT}/modules" --force
done
vela module registry add local "http://${REG_CLUSTER_HOST}:${REG_PORT}/modules" --type oci
for m in "${MODULES[@]}"; do
    echo "Deploying module $m..."
    vela module deploy "$m" --registry local --timeout 20m
done

cat <<MSG

✓ Cluster '$CLUSTER' runs KubeVela $VELA_VERSION with the agent-substrate and kagent modules.
  Host:  export KUBECONFIG=$PWD/substrate.kubeconfig
  Check: kubectl -n vela-system get applications; vela ls -A
  The model API key goes in Secret kagent-provider-values (key values.yaml) in namespace kagent.
MSG
