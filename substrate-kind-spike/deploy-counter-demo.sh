#!/bin/bash
# Substrate counter demo (demos/counter) on the cluster made by
# create-kind-cluster1.12.sh, without ate-setup: the install here is the
# agent-substrate module, so the demo's pieces are done one by one.
#
#   1. a containerd mirror on the kind nodes: localhost:5001 -> the local registry
#      (the same substrate-modules-registry the modules are published to)
#   2. agent-substrate module 0.2.0: adds the atenet-client ServiceAccount and lets
#      it through atenet-router, which `kubectl ate proxy` needs
#   3. kubectl-ate and the counter image, built from kagent-dev/substrate at the
#      tag matching the installed charts (SUBSTRATE_REF, default v1.0.0)
#   4. the counter WorkerPool as a KubeVela Application (apps/counter-workerpool.yaml,
#      type agent-substrate/v1/workerpool)
#   5. the ate-demo-counter atespace, the counter ActorTemplate and actor my-counter-1
#
# Usage: ./deploy-counter-demo.sh        (rerunnable: existing pieces are kept)
# Env: KIND_CLUSTER_NAME (substrate), SUBSTRATE_REF (v1.0.0),
#      VELA_BIN (~/workspace/kubevela/bin/vela, else vela on PATH),
#      MODULES_DIR (../../catalog/experimental/modules), KO_VERSION (v0.17.1)
# Needs: docker, kind, kubectl, go, git. ko is run with `go run` if not on PATH.
# Writes bin/kubectl-ate and .cache/substrate here (gitignored).
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER="${KIND_CLUSTER_NAME:-substrate}"
SUBSTRATE_REF="${SUBSTRATE_REF:-v1.0.0}"
MODULES_DIR="${MODULES_DIR:-$PWD/../../catalog/experimental/modules}"
KO_VERSION="${KO_VERSION:-v0.17.1}"
REG_NAME="substrate-modules-registry"
REG_PORT=5001
ATESPACE="ate-demo-counter"
ACTOR="my-counter-1"

for tool in docker kind kubectl go git; do
    command -v "$tool" >/dev/null || { echo "✗ $tool not found on PATH" >&2; exit 1; }
done
VELA_BIN="${VELA_BIN:-}"
if [ -z "$VELA_BIN" ]; then
    if [ -x "$HOME/workspace/kubevela/bin/vela" ]; then
        VELA_BIN="$HOME/workspace/kubevela/bin/vela"
    else
        VELA_BIN="$(command -v vela || true)"
    fi
fi
if [ -z "$VELA_BIN" ] || ! "$VELA_BIN" module --help >/dev/null 2>&1; then
    echo "✗ need a vela CLI with 'vela module' (build ~/workspace/kubevela/bin/vela or set VELA_BIN)" >&2
    exit 1
fi
[ -f substrate.kubeconfig ] || { echo "✗ substrate.kubeconfig not found: run ./create-kind-cluster1.12.sh first" >&2; exit 1; }
export KUBECONFIG="$PWD/substrate.kubeconfig"
kubectl get nodes >/dev/null || { echo "✗ cannot reach cluster '$CLUSTER'" >&2; exit 1; }

# wait_app NAMESPACE NAME MINUTES: wait for an Application to reach running.
wait_app() {
    local ns="$1" app="$2" deadline=$((SECONDS + $3 * 60)) prev="" cur
    echo "Waiting for Application $ns/$app (up to $3m)..."
    while [ $SECONDS -lt $deadline ]; do
        cur="$(kubectl -n "$ns" get application "$app" \
            -o jsonpath='{.status.status} | {range .status.workflow.steps[*]}{.name}={.phase} {end}' 2>/dev/null || true)"
        [ "$cur" != "$prev" ] && [ -n "$cur" ] && echo "  $cur" && prev="$cur"
        case "$cur" in
            "running |"*) echo "✓ $app is running"; return 0 ;;
            "workflowFailed"*)
                echo "✗ $app failed:" >&2
                kubectl -n "$ns" get application "$app" \
                    -o jsonpath='{range .status.workflow.steps[?(@.phase=="failed")]}{.name}: {.message}{"\n"}{end}' >&2
                exit 1 ;;
        esac
        sleep 10
    done
    echo "✗ $app did not reach running in $3m" >&2
    exit 1
}

# 1. Registry mirror. Actor images are pulled by the node's containerd, so
# localhost:5001 must resolve on the nodes too (same setup as the fork's
# hack/create-kind-cluster.sh, with our registry container).
echo "Configuring the localhost:${REG_PORT} registry mirror on the nodes..."
if ! docker ps --format '{{.Names}}' | grep -qx "$REG_NAME"; then
    docker rm -f "$REG_NAME" >/dev/null 2>&1 || true
    docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --name "$REG_NAME" registry:2 >/dev/null
fi
docker network connect kind "$REG_NAME" 2>/dev/null || true
for node in $(kind get nodes --name "$CLUSTER"); do
    docker exec "$node" mkdir -p "/etc/containerd/certs.d/localhost:${REG_PORT}"
    printf '[host."http://%s:5000"]\n' "$REG_NAME" |
        docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/localhost:${REG_PORT}/hosts.toml"
done

# 2. Module 0.2.0 (atenet-client). Pin the deploy Application to the new version
# so the module is fetched and rendered again.
module_version="$(sed -n 's/^version: *"\(.*\)"/\1/p' "$MODULES_DIR/agent-substrate/_module.cue")"
if kubectl -n ate-system get serviceaccount atenet-client >/dev/null 2>&1; then
    echo "✓ agent-substrate already has atenet-client"
else
    echo "Upgrading the agent-substrate module to $module_version..."
    "$VELA_BIN" module publish "$MODULES_DIR/agent-substrate" "http://localhost:${REG_PORT}/modules" --force
    kubectl -n vela-system patch application module-agent-substrate-deploy --type=json \
        -p "[{\"op\":\"replace\",\"path\":\"/spec/components/0/properties/version\",\"value\":\"$module_version\"}]"
    wait_app vela-system module-agent-substrate-deploy 10
    for _ in $(seq 60); do
        kubectl -n ate-system get serviceaccount atenet-client >/dev/null 2>&1 && break
        sleep 5
    done
    kubectl -n ate-system get serviceaccount atenet-client >/dev/null
    wait_app vela-system agent-substrate 25
fi

# 3. kubectl-ate and the counter image, from the fork at the installed version.
if [ ! -d .cache/substrate/.git ]; then
    echo "Cloning kagent-dev/substrate $SUBSTRATE_REF..."
    git clone --quiet --depth 1 --branch "$SUBSTRATE_REF" https://github.com/kagent-dev/substrate.git .cache/substrate
fi
echo "Building kubectl-ate..."
mkdir -p bin
go build -C .cache/substrate -o "$PWD/bin/kubectl-ate" ./cmd/kubectl-ate
ATE="$PWD/bin/kubectl-ate"

case "$(docker info --format '{{.Architecture}}')" in
    aarch64|arm64) platform=linux/arm64 ;;
    *) platform=linux/amd64 ;;
esac
echo "Building the counter image ($platform) into localhost:${REG_PORT}..."
KO=(ko)
command -v ko >/dev/null || KO=(go run "github.com/google/ko@${KO_VERSION}")
image="$(cd .cache/substrate && KO_DOCKER_REPO="localhost:${REG_PORT}/demos" \
    "${KO[@]}" build --base-import-paths --platform="$platform" ./demos/counter | tail -1)"
echo "  $image"

# 4. WorkerPool, through the agent-substrate module's definition.
kubectl create namespace "$ATESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f apps/counter-workerpool.yaml
wait_app "$ATESPACE" counter-workerpool 5
kubectl -n "$ATESPACE" wait workerpool/counter --for=jsonpath='{.status.readyReplicas}'=1 --timeout=5m

# 5. Atespace, ActorTemplate (immutable: kept if it exists) and the actor.
"$ATE" get atespace "$ATESPACE" >/dev/null 2>&1 || "$ATE" create atespace "$ATESPACE"
if "$ATE" get actor-template counter -a "$ATESPACE" >/dev/null 2>&1; then
    echo "✓ ActorTemplate counter exists (delete it to pick up a new image)"
else
    echo "Creating the counter ActorTemplate..."
    sed -e "s#ko://go.ate.dev/substrate/demos/counter#${image}#" -e '/^\${/d' \
        .cache/substrate/demos/counter/counter-template.yaml.tmpl | "$ATE" create actor-template -f -
fi
# The golden snapshot is taken first; creating the actor retries until it is ready.
if ! "$ATE" get actor "$ACTOR" -a "$ATESPACE" >/dev/null 2>&1; then
    echo "Creating actor $ACTOR (waits for the template's golden snapshot)..."
    for i in $(seq 60); do
        "$ATE" create actor "$ACTOR" -a "$ATESPACE" --template counter && break
        [ "$i" = 60 ] && { echo "✗ could not create $ACTOR; check: $ATE get actor-templates -a $ATESPACE" >&2; exit 1; }
        sleep 10
    done
fi
"$ATE" get actor "$ACTOR" -a "$ATESPACE"

cat <<MSG

✓ Counter demo is deployed (atespace $ATESPACE, actor $ACTOR).
  Terminal 1:  KUBECONFIG=$KUBECONFIG $ATE proxy actor $ACTOR -a $ATESPACE
  Terminal 2:  curl -X POST http://localhost:8000          # counters go 1, 2, 3...
               KUBECONFIG=$KUBECONFIG $ATE suspend actor $ACTOR -a $ATESPACE
               curl -X POST http://localhost:8000          # resumes from the snapshot, keeps counting
MSG
