#!/usr/bin/env bash
# KubeVela 1.12 demo: One Application, sized by its namespace
# The same YAML, applied into two namespaces, takes its tier label, env var and replica count from a namespace label read through the vela-env source.
#
# Needs: featureGates.enableCelExpressions=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./03-sized-by-namespace.sh            run the demo and check the result
#   ./03-sized-by-namespace.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-cel-3          # no tier label: a dev namespace
PROD=demo-cel-3-prod   # labelled tier=prod

cleanup() {
  kubectl delete namespace "$NS" "$PROD" --ignore-not-found --wait=false
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
kubectl create namespace "$PROD" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Label the prod namespace"
kubectl label namespace "$PROD" tier=prod --overwrite

step "Apply the same Application to both namespaces"
APP=$(cat <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: tiered-web
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  sources:
    - name: env
      type: vela-env
      properties: {}
  components:
    - name: web
      type: webservice
      properties:
        image: nginx:1.27
        labels:
          tier: '$(has(source.env.labels.tier) ? source.env.labels.tier : "dev")'
        env:
          - name: TIER
            value: '$(has(source.env.labels.tier) ? source.env.labels.tier.upperAscii() : "DEV")'
      traits:
        - type: scaler
          properties:
            replicas: '$(has(source.env.labels.tier) && source.env.labels.tier == "prod" ? 3 : 1)'
EOF
)
echo "$APP" | kubectl apply -n "$NS" -f -
echo "$APP" | kubectl apply -n "$PROD" -f -

step "Wait for both to run"
wait_app tiered-web "$NS"
wait_app tiered-web "$PROD"

step "Check the result"
ctr='{.spec.template.spec.containers[0].env[?(@.name=="TIER")].value}'
expect "dev replicas" "1" "$(kubectl get deploy web -n "$NS" -o jsonpath='{.spec.replicas}')"
expect "dev TIER" "DEV" "$(kubectl get deploy web -n "$NS" -o jsonpath="$ctr")"
expect "dev pod label" "dev" "$(kubectl get deploy web -n "$NS" -o jsonpath='{.spec.template.metadata.labels.tier}')"
expect "prod replicas" "3" "$(kubectl get deploy web -n "$PROD" -o jsonpath='{.spec.replicas}')"
expect "prod TIER" "PROD" "$(kubectl get deploy web -n "$PROD" -o jsonpath="$ctr")"
expect "prod pod label" "prod" "$(kubectl get deploy web -n "$PROD" -o jsonpath='{.spec.template.metadata.labels.tier}')"

echo
echo "PASS: One Application, sized by its namespace"
