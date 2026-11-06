#!/usr/bin/env bash
# KubeVela 1.12 demo: One addon, declared
# Installs the kube-state-metrics addon from the default registry, pinned to a version, as a type: addon component.
#
# Needs: featureGates.enableAddonComponent=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./01-one-addon.sh            run the demo and check the result
#   ./01-one-addon.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-addons-1   # the outer Application lives here; the addon's own Application lands in vela-system

cleanup() {
  kubectl delete app metrics-addon -n "$NS" --ignore-not-found
  # the addon's Application is owned by metrics-addon, so it goes with it
  for _ in $(seq 1 24); do
    kubectl get app addon-kube-state-metrics -n vela-system >/dev/null 2>&1 || break
    sleep 5
  done
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
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

if kubectl get app addon-kube-state-metrics -n vela-system >/dev/null 2>&1 &&
  [ "$(kubectl get app addon-kube-state-metrics -n vela-system -o jsonpath='{.metadata.labels.owner\.oam\.dev/name}')" != metrics-addon ]; then
  fail "kube-state-metrics is already enabled some other way; run 'vela addon disable kube-state-metrics' first"
fi

kubectl wait --for=delete namespace/"$NS" --timeout=120s >/dev/null 2>&1 || true   # a recent --cleanup may still be finishing
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Apply the Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: metrics-addon
spec:
  components:
    - name: kube-state-metrics    # addon name defaults to the component name
      type: addon
      properties:
        version: "v0.3.1"         # omit for latest stable
        properties:               # the addon's own parameters
          # the addon's default bitnami image is no longer on Docker Hub
          image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.4.2
EOF

step "Wait for the addon to be installed and healthy"
wait_app metrics-addon "$NS" 420
vela status metrics-addon -n "$NS"

step "Check the result"
expect "addon Application version" "v0.3.1" \
  "$(kubectl get app addon-kube-state-metrics -n vela-system -o jsonpath='{.metadata.labels.addons\.oam\.dev/version}')"
expect "addon Application owner" "metrics-addon" \
  "$(kubectl get app addon-kube-state-metrics -n vela-system -o jsonpath='{.metadata.labels.owner\.oam\.dev/name}')"
expect "kube-state-metrics ready replicas" "1" \
  "$(kubectl get deploy kube-state-metrics -n o11y-system -o jsonpath='{.status.readyReplicas}')"
vela addon list 2>/dev/null | grep -E '^NAME|kube-state-metrics' || true

echo
echo "PASS: One addon, declared"
