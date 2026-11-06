#!/usr/bin/env bash
# KubeVela 1.12 demo: One step, three items
# A ConfigMap per team, created by the built-in apply-object step looped over a list, all at once.
#
# Needs: KubeVela 1.12 (no feature gate), and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./01-one-step-three-items.sh            run the demo and check the result
#   ./01-one-step-three-items.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-loops-1

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
  name: team-configs
spec:
  components:
    - name: web
      type: webservice
      properties:
        image: nginx:1.27
  workflow:
    steps:
      - name: deploy
        type: deploy
        properties:
          policies: []
      - name: team-config
        type: apply-object
        forEach:
          items: [frontend, backend, data]
          mode: DAG               # all at once; StepByStep is the default
        properties:
          value:
            apiVersion: v1
            kind: ConfigMap
            metadata:
              namespace: demo-loops-1
            data:
              owner: platform
        inputs:
          - from: each.item
            parameterKey: value.metadata.name
EOF

step "Wait for it to run"
wait_app team-configs "$NS"
vela status team-configs -n "$NS"

step "Check the result"
subs=$(kubectl get app team-configs -n "$NS" -o jsonpath='{range .status.workflow.steps[?(@.name=="team-config")].subSteps[*]}{.name}={.phase} {end}')
expect "item steps" "team-config-0=succeeded team-config-1=succeeded team-config-2=succeeded " "$subs"
kubectl get configmap frontend backend data -n "$NS"
for cm in frontend backend data; do
  expect "$cm owner" "platform" "$(kubectl get configmap "$cm" -n "$NS" -o jsonpath='{.data.owner}')"
done

echo
echo "PASS: One step, three items"
