#!/usr/bin/env bash
# KubeVela 1.12 demo: Chained loops with forEach.from
# The first loop creates ConfigMaps and outputs where each landed; once it succeeds the outputs are collected into a list, and a second loop runs over it with from.
#
# Needs: KubeVela 1.12 (no feature gate), and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./05-chained-from-outputs.sh            run the demo and check the result
#   ./05-chained-from-outputs.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-loops-5

cleanup() {
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

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Apply the Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: queue-inventory
spec:
  components: []
  workflow:
    steps:
      - name: create-queues
        type: apply-object
        forEach:
          items: [orders, invoices, refunds]
        inputs:
          - from: each.item
            parameterKey: value.metadata.name
        properties:
          value:
            apiVersion: v1
            kind: ConfigMap
            metadata:
              namespace: demo-loops-5
            data:
              kind: queue
        outputs:
          - name: queues
            valueFrom: apply.$returns.value.metadata.namespace + "/" + apply.$returns.value.metadata.name
      - name: announce
        type: print-message-in-status
        forEach:
          from: queues            # ["demo-loops-5/orders", "demo-loops-5/invoices", "demo-loops-5/refunds"]
        inputs:
          - from: each.item
            parameterKey: message
EOF

step "Wait for it to run"
wait_app queue-inventory "$NS"
kubectl get app queue-inventory -n "$NS" \
  -o jsonpath='{range .status.workflow.steps[?(@.name=="announce")].subSteps[*]}{.name}{"\t"}{.message}{"\n"}{end}'

step "Check the result"
got=$(kubectl get app queue-inventory -n "$NS" \
  -o jsonpath='{range .status.workflow.steps[?(@.name=="announce")].subSteps[*]}{.name}={.message} {end}')
expect "announce items" "announce-0=$NS/orders announce-1=$NS/invoices announce-2=$NS/refunds " "$got"
kubectl get configmap orders invoices refunds -n "$NS"

echo
echo "PASS: Chained loops with forEach.from"
