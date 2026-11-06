#!/usr/bin/env bash
# KubeVela 1.12 demo: Values from the render context
# Environment variables filled from where the app is rendered, plus an escaped shell substitution.
#
# Needs: featureGates.enableCelExpressions=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./01-render-context.sh            run the demo and check the result
#   ./01-render-context.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-cel-1

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
  name: web
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  components:
    - name: web
      type: webservice
      properties:
        image: nginx:1.27
        cmd: ["sh", "-c", "echo started on $$(hostname) && exec nginx -g 'daemon off;'"]
        env:
          - name: NAMESPACE
            value: "$(context.namespace)"
          - name: APP
            value: "$(context.appName)"
EOF

step "Wait for it to run"
wait_app web "$NS"
kubectl rollout status deploy/web -n "$NS" --timeout=180s >/dev/null

step "Check the result"
kubectl exec deploy/web -n "$NS" -- env | grep -E 'NAMESPACE|APP'
expect "NAMESPACE env" "$NS" "$(kubectl exec deploy/web -n "$NS" -- printenv NAMESPACE)"
expect "APP env" "web" "$(kubectl exec deploy/web -n "$NS" -- printenv APP)"
expect "escaped command reaches the container" "echo started on \$(hostname) && exec nginx -g 'daemon off;'" \
  "$(kubectl get deploy web -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].command[2]}')"
pod=$(kubectl get pods -n "$NS" -l app.oam.dev/component=web --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
expect "the shell expanded \$(hostname)" "started on $pod" "$(kubectl logs -n "$NS" "$pod" | head -1)"

echo
echo "PASS: Values from the render context"
