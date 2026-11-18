#!/bin/bash
# Same kind cluster as create-kind-cluster.sh (name "substrate", deleted first if
# it exists), then KubeVela 1.12 with the module component enabled, then the
# agent-substrate and kagent MODULES deployed (the Application `vela module deploy` builds).
#
#   1. ./create-kind-cluster.sh        (recreates the cluster, proxy ARP, kubeconfigs)
#   2. helm install vela-core 1.12.0-alpha.1 with featureGates.enableModuleComponent=true
#   3. a local OCI registry (container "substrate-modules-registry": host port 5001 for publishing,
#      its kind-network IP for vela-core)
#   4. vela module publish, then the type: module Application for agent-substrate, then kagent
#
# Usage: ./create-kind-cluster1.12.sh [--zscaler] [--skip-modules]
#   --zscaler       passed to create-kind-cluster.sh (trust the proxy CA)
#   --skip-modules  stop after installing KubeVela
# Env: KIND_CLUSTER_NAME (substrate), VELA_VERSION (v1.12.0-alpha.1),
#      MODULES_DIR (../../catalog/experimental/modules),
#      MODULE_REGISTRY_HOST_PORT (5001),
#      VELA_BIN: the vela CLI. Default ~/workspace/kubevela/bin/vela (a build of
#      kubevela master), else `vela` on PATH. It must have `vela module`.
# Needs: docker, kind, kubectl, helm, and that 1.12 vela CLI. Build it with
#   make -C ~/workspace/kubevela vela-cli    (output: bin/vela)
# Not tested from the dev container (no Docker there). Tear down with ./delete-kind-cluster.sh.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER="${KIND_CLUSTER_NAME:-substrate}"
VELA_VERSION="${VELA_VERSION:-v1.12.0-alpha.1}"
MODULES_DIR="${MODULES_DIR:-$PWD/../../catalog/experimental/modules}"
REG_NAME="substrate-modules-registry"
REG_PORT="${MODULE_REGISTRY_HOST_PORT:-5001}"
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

for tool in docker kind kubectl helm; do
    command -v "$tool" >/dev/null || { echo "✗ $tool not found on PATH" >&2; exit 1; }
done

# The module commands need a 1.12 CLI built from kubevela master, which is not the
# vela on PATH (the demos pin the alpha release there; never replace it).
VELA_BIN="${VELA_BIN:-}"
if [ -z "$VELA_BIN" ]; then
    if [ -x "$HOME/workspace/kubevela/bin/vela" ]; then
        VELA_BIN="$HOME/workspace/kubevela/bin/vela"
    else
        VELA_BIN="$(command -v vela || true)"
    fi
fi
if [ -z "$VELA_BIN" ] || [ ! -x "$VELA_BIN" ]; then
    echo "✗ no vela CLI: build ~/workspace/kubevela/bin/vela or set VELA_BIN" >&2
    exit 1
fi
if ! "$VELA_BIN" module --help >/dev/null 2>&1; then
    echo "✗ $VELA_BIN has no 'vela module'; build the CLI from kubevela master:" >&2
    echo "  make -C ~/workspace/kubevela vela-cli" >&2
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
# It is also attached to the kind network, so pods reach it by that IP. The host
# cannot resolve cluster-side names (host.docker.internal is not a host name), so
# the host only talks to it on localhost and `vela module deploy`, which fetches
# from the host too, is replaced below by the Application it would apply.
if ! docker ps --format '{{.Names}}' | grep -qx "$REG_NAME"; then
    docker rm -f "$REG_NAME" >/dev/null 2>&1 || true
    docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --name "$REG_NAME" registry:2 >/dev/null
fi
docker network connect kind "$REG_NAME" 2>/dev/null || true
REG_IP="$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "$REG_NAME")"
[ -n "$REG_IP" ] || { echo "✗ registry $REG_NAME has no IP on the kind network" >&2; exit 1; }
sleep 2

# 4. Publish, register the registry under the address vela-core uses, then apply the
# type: module Application that `vela module deploy` builds (name module-<m>-deploy)
# and wait for it. The registry is stored in the cluster with the in-cluster URL.
for m in "${MODULES[@]}"; do
    echo "Publishing module $m..."
    "$VELA_BIN" module publish "$MODULES_DIR/$m" "http://localhost:${REG_PORT}/modules" --force
done
"$VELA_BIN" module registry add local "http://${REG_IP}:5000/modules" --type oci

# wait_app NAME MINUTES: wait for a vela-system Application to reach running.
# Prints its workflow steps as they change; stops early on workflowFailed and
# prints the failed step's message.
wait_app() {
    local app="$1" deadline=$((SECONDS + $2 * 60)) prev="" cur
    echo "Waiting for Application $app (up to $2m)..."
    while [ $SECONDS -lt $deadline ]; do
        cur="$(kubectl -n vela-system get application "$app" \
            -o jsonpath='{.status.status} | {range .status.workflow.steps[*]}{.name}={.phase} {end}' 2>/dev/null || true)"
        [ "$cur" != "$prev" ] && [ -n "$cur" ] && echo "  $cur" && prev="$cur"
        case "$cur" in
            "running |"*) echo "✓ $app is running"; return 0 ;;
            "workflowFailed"*)
                echo "✗ $app failed:" >&2
                kubectl -n vela-system get application "$app" \
                    -o jsonpath='{range .status.workflow.steps[?(@.phase=="failed")]}{.name}: {.message}{"\n"}{end}' >&2
                exit 1 ;;
        esac
        sleep 10
    done
    echo "✗ $app did not reach running in $2m; check: kubectl -n vela-system get application $app -o yaml" >&2
    exit 1
}

for m in "${MODULES[@]}"; do
    echo "Deploying module $m..."
    kubectl apply -f - <<YAML
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: module-${m}-deploy
  namespace: vela-system
spec:
  components:
  - name: ${m}
    type: module
    properties:
      module: ${m}
      registry: local
      version: ""
YAML
    wait_app "module-${m}-deploy" 10
    # The module's v1 line applies the Application that installs the charts; its
    # name is the module name. Wait for it too, so kagent starts on a ready substrate.
    wait_app "$m" 25
done

cat <<MSG

✓ Cluster '$CLUSTER' runs KubeVela $VELA_VERSION with the agent-substrate and kagent modules.
  Host:  export KUBECONFIG=$PWD/substrate.kubeconfig
  Check: kubectl -n vela-system get applications; vela ls -A
  The model API key goes in Secret kagent-provider-values (key values.yaml) in namespace kagent.
MSG
