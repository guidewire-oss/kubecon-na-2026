#!/usr/bin/env bash
# KubeVela 1.12 demo: Use an addon only where it runs
# A workflow step reads the vela-addon source in its if, so the FluxCD HelmRepository is applied only when the fluxcd addon is running; elsewhere the app deploys without it and says why.
#
# Needs: featureGates.enableCelExpressions=true, the vela CLI 1.12, and the fluxcd addon (02-addon-chain.sh installs it).
# Runs against the cluster in your current kubeconfig.
#
#   ./03-gate-on-addon.sh            run the demo and check the result
#   ./03-gate-on-addon.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-addons-3

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
step_phase() { kubectl get app web -n "$NS" -o jsonpath="{.status.workflow.steps[?(@.name==\"$1\")].phase}"; }

[ "$(kubectl get app addon-fluxcd -n vela-system -o jsonpath='{.status.status}' 2>/dev/null)" = running ] ||
  fail "the fluxcd addon is not running; run 02-addon-chain.sh first"

kubectl wait --for=delete namespace/"$NS" --timeout=120s >/dev/null 2>&1 || true
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
  sources:
    - name: flux
      type: vela-addon
      properties:
        name: fluxcd
  components:
    - name: web
      type: webservice
      properties:
        image: nginx:1.27
    - name: charts
      type: k8s-objects
      properties:
        objects:
          - apiVersion: source.toolkit.fluxcd.io/v1beta2
            kind: HelmRepository        # a CRD the fluxcd addon installs
            metadata:
              name: podinfo
            spec:
              url: https://stefanprodan.github.io/podinfo
              interval: 10m
  workflow:
    steps:
      - name: deploy
        type: apply-component
        properties:
          component: web
      - name: charts
        type: apply-component
        if: '$(source.flux.running)'
        properties:
          component: charts
      - name: no-flux
        type: print-message-in-status
        if: '$(!source.flux.running)'
        properties:
          message: "fluxcd is not running here, so the chart repository was skipped; restart the workflow once it is"
EOF

step "Wait for it to run"
wait_app web "$NS"
vela status web -n "$NS"

step "Check the result"
expect "charts step" "succeeded" "$(step_phase charts)"
expect "no-flux step" "skipped" "$(step_phase no-flux)"
wait_for "HelmRepository Ready (fetched by FluxCD)" "True" 120 \
  kubectl get helmrepository podinfo -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

echo
echo "PASS: Use an addon only where it runs"
