#!/usr/bin/env bash
# KubeVela 1.12 demo: The list comes from a source
# The platform owns the list of teams in a ConfigMap; add a team there and a later run creates its ConfigMap, with no change to the Application.
#
# Needs: featureGates.enableCelExpressions=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./02-items-from-source.sh            run the demo and check the result
#   ./02-items-from-source.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-loops-2

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
items() {
  kubectl get app team-configs-from-source -n "$NS" \
    -o jsonpath='{range .status.workflow.steps[?(@.name=="team-config")].subSteps[*]}{.name} {end}'
}

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Create the platform's list of teams"
kubectl create configmap rollout-targets -n "$NS" \
  --from-literal=teams=frontend,backend,data \
  --dry-run=client -o yaml | kubectl apply -f -

step "Apply the Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: team-configs-from-source
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  sources:
    - name: targets
      type: configmap-local
      properties:
        name: rollout-targets
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
          items: '$(has(source.targets.data.teams) ? source.targets.data.teams.split(",") : [])'
        properties:
          value:
            apiVersion: v1
            kind: ConfigMap
            metadata:
              namespace: '$(context.namespace)'
            data:
              owner: platform
        inputs:
          - from: each.item
            parameterKey: value.metadata.name
EOF

step "Wait for it to run"
wait_app team-configs-from-source "$NS"

step "Check the first run"
expect "item steps" "team-config-0 team-config-1 team-config-2 " "$(items)"
kubectl get configmap frontend backend data -n "$NS"

step "Add a team to the list, then rerun the workflow"
kubectl patch configmap rollout-targets -n "$NS" -p '{"data":{"teams":"frontend,backend,data,payments"}}'
# configmap-local caches for 5m, and a new run reads the source through that cache,
# so rerun until the run sees the new list.
echo "note: configmap-local caches its value for up to 5 minutes; rerunning once a minute until payments shows up"
for i in $(seq 1 8); do
  vela workflow restart team-configs-from-source -n "$NS" >/dev/null
  sleep 5
  wait_app team-configs-from-source "$NS"
  if kubectl get configmap payments -n "$NS" >/dev/null 2>&1; then break; fi
  [ "$i" = 8 ] && fail "payments never appeared"
  echo "  run $i still read the cached list; waiting 60s"
  sleep 60
done

step "Check the result"
expect "item steps" "team-config-0 team-config-1 team-config-2 team-config-3 " "$(items)"
expect "payments owner" "platform" "$(kubectl get configmap payments -n "$NS" -o jsonpath='{.data.owner}')"

echo
echo "PASS: The list comes from a source"
