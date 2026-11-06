#!/usr/bin/env bash
# KubeVela 1.12 demo: Loop items read in expressions
# The team roster comes from a ConfigMap source, and each pass builds its ConfigMap's name and data from each.item, each.index and each.key with CEL string functions.
#
# Needs: featureGates.enableCelExpressions=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./03-source-items-in-expressions.sh            run the demo and check the result
#   ./03-source-items-in-expressions.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-loops-3

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

step "Create the platform's team roster"
kubectl create configmap team-roster -n "$NS" \
  --from-literal=teams='Payments:alice, Search:carol, Checkout:bob' \
  --dry-run=client -o yaml | kubectl apply -f -

step "Apply the Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: team-roster
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  sources:
    - name: roster
      type: configmap-local
      properties:
        name: team-roster
  components: []
  workflow:
    steps:
      - name: team
        type: apply-object
        forEach:
          items: '$(has(source.roster.data.teams) ? source.roster.data.teams.split(",") : [])'
        properties:
          value:
            apiVersion: v1
            kind: ConfigMap
            metadata:
              name: 'team-$(each.item.split(":")[0].trim().lowerAscii())'
              namespace: '$(context.namespace)'
            data:
              team: '$(each.item.split(":")[0].trim().upperAscii())'
              owner: '$(each.item.split(":")[1].trim())'
              email: '$(each.item.split(":")[1].trim())@example.com'
              position: '$(each.index + 1) of $(source.roster.data.teams.split(",").size())'
              step: 'team-$(each.key)'
EOF

step "Wait for it to run"
wait_app team-roster "$NS"
vela status team-roster -n "$NS"

step "Check the result"
kubectl get configmap team-payments team-search team-checkout -n "$NS"
expect "team-payments" '{"email":"alice@example.com","owner":"alice","position":"1 of 3","step":"team-0","team":"PAYMENTS"}' \
  "$(kubectl get configmap team-payments -n "$NS" -o jsonpath='{.data}')"
expect "team-search" '{"email":"carol@example.com","owner":"carol","position":"2 of 3","step":"team-1","team":"SEARCH"}' \
  "$(kubectl get configmap team-search -n "$NS" -o jsonpath='{.data}')"
expect "team-checkout" '{"email":"bob@example.com","owner":"bob","position":"3 of 3","step":"team-2","team":"CHECKOUT"}' \
  "$(kubectl get configmap team-checkout -n "$NS" -o jsonpath='{.data}')"

echo
echo "PASS: Loop items read in expressions"
