#!/usr/bin/env bash
# KubeVela 1.12 demo: Scale from a platform ConfigMap
# The replica count lives in a ConfigMap the platform owns; patching it rescales the Deployment with no edit to the Application.
#
# Needs: featureGates.enableCelExpressions=true and featureGates.enableSourceAutoUpdate=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./01-scale-from-configmap.sh            run the demo and check the result (about 6 minutes: it waits out the source cache)
#   ./01-scale-from-configmap.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-sources-1

cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  # source cache entries outlive the Application, so a rerun within the TTL would read the old value
  kubectl delete secret -n vela-system -l sourcedefinition.oam.dev/ctx.namespace="$NS" --ignore-not-found
}
if [ "${1:-}" = "--cleanup" ]; then cleanup; exit 0; fi

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# wait_app <app> <namespace> [timeout seconds]: until the Application is running
wait_app() {
  local app=$1 ns=$2 t=${3:-300} s=""
  for _ in $(seq 1 $((t / 5))); do
    s=$(kubectl get app "$app" -n "$ns" -o jsonpath='{.status.status}' 2>/dev/null || true)
    [ "$s" = running ] && return 0
    sleep 5
  done
  vela status "$app" -n "$ns" || true
  fail "$app in $ns is '$s', not running, after ${t}s"
}
# expect <description> <expected> <actual>
expect() { [ "$2" = "$3" ] || fail "$1: expected '$2', got '$3'"; echo "ok: $1 = $3"; }
# wait_for <description> <expected> <timeout seconds> <command...>: poll until the command prints the value
wait_for() {
  local d=$1 want=$2 t=$3 got=""; shift 3
  for _ in $(seq 1 $((t / 5))); do
    got=$("$@" 2>/dev/null || true)
    [ "$got" = "$want" ] && { echo "ok: $d = $got"; return 0; }
    sleep 5
  done
  fail "$d: expected '$want', got '$got' after ${t}s"
}
replicas() { kubectl get deploy shop -n "$NS" -o jsonpath='{.spec.replicas}'; }

kubectl wait --for=delete namespace/"$NS" --timeout=120s >/dev/null 2>&1 || true
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Create the platform's data"
kubectl create configmap shop-scaling -n "$NS" \
  --from-literal=replicas=2 --from-literal=mode=normal \
  --dry-run=client -o yaml | kubectl apply -f -

step "Bind and read it"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: shop
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  sources:
    - name: scaling             # your binding name; must be an identifier
      type: configmap-local
      properties:
        name: shop-scaling
      autoUpdate: true          # re-dispatch when the value changes
  components:
    - name: shop
      type: webservice
      properties:
        image: nginx:1.27
        env:
          - name: SCALING_MODE
            value: '$(has(source.scaling.data.mode) ? source.scaling.data.mode : "normal")'
      traits:
        - type: scaler
          properties:
            # a whole-value expression keeps its type, so this is an int
            replicas: '$(has(source.scaling.data.replicas) ? int(source.scaling.data.replicas) : 1)'
EOF

step "See what it resolved"
wait_app shop "$NS"
vela status shop -n "$NS" --sources
wait_for "replicas" "2" 60 replicas
expect "SCALING_MODE" "normal" \
  "$(kubectl get deploy shop -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SCALING_MODE")].value}')"

step "Scale up for peak"
kubectl patch configmap shop-scaling -n "$NS" \
  -p '{"data":{"replicas":"5","mode":"peak"}}'
expires=$(kubectl get app shop -n "$NS" -o jsonpath='{.status.sources[0].resolutions[0].expiresAt}')
echo "note: configmap-local caches for 5 minutes; the entry expires at $expires (UTC) and is re-read at the next reconcile after that (the resync runs every 5 minutes)"
wait_for "replicas" "5" 660 replicas
wait_for "SCALING_MODE" "peak" 60 \
  kubectl get deploy shop -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SCALING_MODE")].value}'
expect "workflow not re-run, revision" "shop-v1" "$(kubectl get app shop -n "$NS" -o jsonpath='{.status.latestRevision.name}')"
vela status shop -n "$NS" --sources

echo "note: after the re-dispatch, health in status catches up at the next resync"
wait_app shop "$NS" 420

echo
echo "PASS: Scale from a platform ConfigMap"
