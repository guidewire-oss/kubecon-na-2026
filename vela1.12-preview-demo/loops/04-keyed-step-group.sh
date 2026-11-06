#!/usr/bin/env bash
# KubeVela 1.12 demo: Keyed loop over a step group
# Each object item gets a ConfigMap and a status line, and every generated step is named by its key (team and env) rather than its index.
#
# Needs: featureGates.enableCelExpressions=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./04-keyed-step-group.sh            run the demo and check the result
#   ./04-keyed-step-group.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-loops-4

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
  name: team-settings
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  components: []
  workflow:
    steps:
      - name: onboard
        type: step-group
        forEach:
          key: [team, env]
          items:
            - {team: payments, env: dev,  owner: alice}
            - {team: payments, env: prod, owner: bob}
            - {team: search,   env: dev,  owner: carol}
        subSteps:
          - name: settings
            type: apply-object
            properties:
              value:
                apiVersion: v1
                kind: ConfigMap
                metadata:
                  name: 'settings-$(each.key)'
                  namespace: '$(context.namespace)'
                data:
                  team: '$(each.item.team)'
                  env: '$(each.item.env)'
                  owner: '$(each.item.owner)'
                  position: '$(string(each.index))'
          - name: report
            type: print-message-in-status
            dependsOn: [settings]
            properties:
              message: 'item $(each.index) ($(each.key)) is owned by $(each.item.owner)'
EOF

step "Wait for it to run"
wait_app team-settings "$NS"
kubectl get app team-settings -n "$NS" \
  -o jsonpath='{range .status.workflow.steps[0].subSteps[*]}{.name}{"\t"}{.phase}{"\t"}{.message}{"\n"}{end}'

step "Check the result"
names=$(kubectl get app team-settings -n "$NS" -o jsonpath='{.status.workflow.steps[0].subSteps[*].name}' | tr ' ' '\n' | sort | paste -sd' ' -)
expect "keyed step names" "onboard-payments-dev-report onboard-payments-dev-settings onboard-payments-prod-report onboard-payments-prod-settings onboard-search-dev-report onboard-search-dev-settings" "$names"
msg() { kubectl get app team-settings -n "$NS" -o jsonpath="{.status.workflow.steps[0].subSteps[?(@.name==\"$1\")].message}"; }
expect "payments-prod report" "item 1 (payments-prod) is owned by bob" "$(msg onboard-payments-prod-report)"
expect "search-dev report" "item 2 (search-dev) is owned by carol" "$(msg onboard-search-dev-report)"
expect "settings-payments-prod" '{"env":"prod","owner":"bob","position":"1","team":"payments"}' \
  "$(kubectl get configmap settings-payments-prod -n "$NS" -o jsonpath='{.data}')"
kubectl get configmap settings-payments-dev settings-payments-prod settings-search-dev -n "$NS"

echo
echo "PASS: Keyed loop over a step group"
