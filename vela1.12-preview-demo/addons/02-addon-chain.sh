#!/usr/bin/env bash
# KubeVela 1.12 demo: A chained stack that passes data
# FluxCD, then cert-manager and KEDA (both of which need FluxCD), then a ConfigMap recording the version of each addon read from its live Application.
#
# Needs: featureGates.enableAddonComponent=true and featureGates.enableCelExpressions=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./02-addon-chain.sh            run the demo and check the result
#   ./02-addon-chain.sh --cleanup  remove everything it created
set -euo pipefail

# The stack lives in vela-system beside the addon Applications it owns: on alpha.1 a component read
# only finds a workload in the reading Application's own namespace, and an addon's workload is its
# Application in vela-system.
NS=vela-system

cleanup() {
  kubectl delete app platform-stack -n "$NS" --ignore-not-found
  for _ in $(seq 1 60); do
    kubectl get app addon-fluxcd addon-cert-manager addon-keda -n vela-system 2>/dev/null | grep -q addon- || break
    sleep 5
  done
  kubectl delete configmap addon-inventory -n "$NS" --ignore-not-found
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

for a in fluxcd cert-manager keda; do
  owner=$(kubectl get app "addon-$a" -n vela-system -o jsonpath='{.metadata.labels.owner\.oam\.dev/name}' 2>/dev/null || true)
  if kubectl get app "addon-$a" -n vela-system >/dev/null 2>&1 && [ "$owner" != platform-stack ]; then
    fail "$a is already enabled some other way; run 'vela addon disable $a' first"
  fi
done

step "Apply the stack"
kubectl apply -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: platform-stack
  namespace: vela-system
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  components:
    - name: fluxcd
      type: addon
      properties:
        version: "3.0.2"
        properties:
          # alpha.1 installs an addon's definitions into the namespace of its own
          # topology policy; this keeps FluxCD's helm definition in vela-system,
          # where cert-manager and KEDA look for it
          namespace: vela-system
    - name: certmanager             # names must be identifiers to be read
      type: addon
      dependsOn: [fluxcd]           # cert-manager is installed with FluxCD's helm component
      properties:
        addon: cert-manager
        version: "2.2.0"
    - name: keda
      type: addon
      dependsOn: [fluxcd]           # so is KEDA
      properties:
        version: "2.8.3"
    - name: inventory               # renders once every addon it reads is healthy
      type: k8s-objects
      properties:
        objects:
          - apiVersion: v1
            kind: ConfigMap
            metadata:
              name: addon-inventory
            data:
              fluxcd: '$(component.fluxcd.output.metadata.labels["addons.oam.dev/version"])'
              certManager: '$(component.certmanager.output.metadata.labels["addons.oam.dev/version"])'
              keda: '$(component.keda.output.metadata.labels["addons.oam.dev/version"])'
  policies:
    - name: gc
      type: garbage-collect
      properties:
        order: dependency           # on delete, remove cert-manager and KEDA before the FluxCD they need
EOF

step "Wait for the whole stack (FluxCD first, then the two that need it)"
wait_app platform-stack "$NS" 900
vela status platform-stack -n "$NS"

step "Check the result"
expect "fluxcd addon version" "3.0.2" \
  "$(kubectl get app addon-fluxcd -n vela-system -o jsonpath='{.metadata.labels.addons\.oam\.dev/version}')"
expect "inventory fluxcd" "3.0.2" "$(kubectl get configmap addon-inventory -n "$NS" -o jsonpath='{.data.fluxcd}')"
expect "inventory certManager" "2.2.0" "$(kubectl get configmap addon-inventory -n "$NS" -o jsonpath='{.data.certManager}')"
expect "inventory keda" "2.8.3" "$(kubectl get configmap addon-inventory -n "$NS" -o jsonpath='{.data.keda}')"
expect "inventory read edges" "3" \
  "$(kubectl get app platform-stack -n "$NS" -o json | jq '[.status.dependencies[]? | select(.component=="inventory" and .source=="expression")] | length')"
kubectl get configmap addon-inventory -n "$NS" -o yaml

echo
echo "PASS: A chained stack that passes data"
