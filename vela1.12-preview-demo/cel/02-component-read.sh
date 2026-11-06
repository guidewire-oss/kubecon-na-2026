#!/usr/bin/env bash
# KubeVela 1.12 demo: One component reads another
# api reads db's live ConfigMap; the read orders the two and waits for db to be healthy, so no dependsOn is needed.
#
# Needs: featureGates.enableCelExpressions=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./02-component-read.sh            run the demo and check the result
#   ./02-component-read.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-cel-2

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
  name: shop
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  components:
    - name: db
      type: k8s-objects
      properties:
        objects:
          - apiVersion: v1
            kind: ConfigMap
            metadata:
              name: db-info
            data:
              host: db.internal
              port: "5432"
    - name: api
      type: k8s-objects
      properties:
        objects:
          - apiVersion: v1
            kind: ConfigMap
            metadata:
              name: api-config
            data:
              url: 'postgres://$(component.db.output.data.host):$(component.db.output.data.port)/shop'
EOF

step "Wait for it to run"
wait_app shop "$NS"

step "Check the result"
expect "api-config url" "postgres://db.internal:5432/shop" \
  "$(kubectl get configmap api-config -n "$NS" -o jsonpath='{.data.url}')"

echo
echo "PASS: One component reads another"
