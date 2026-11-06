#!/usr/bin/env bash
# KubeVela 1.12 demo: A workflow gated on an earlier step's outputs
# The first step reads a release ConfigMap; a later step runs only on the canary channel, and a summary step reshapes the outputs with CEL.
#
# Needs: featureGates.enableCelExpressions=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./05-gated-on-step-outputs.sh            run the demo and check the result
#   ./05-gated-on-step-outputs.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-cel-5

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
# step_field <app> <step> <field>: a top-level workflow step's status field
step_field() {
  kubectl get app "$1" -n "$NS" -o jsonpath="{.status.workflow.steps[?(@.name==\"$2\")].$3}"
}
# wait_step <app> <step> <phase> [timeout seconds]
wait_step() {
  local t=${4:-180} p=""
  for _ in $(seq 1 $((t / 5))); do
    p=$(step_field "$1" "$2" phase)
    [ "$p" = "$3" ] && return 0
    sleep 5
  done
  vela status "$1" -n "$NS" || true
  fail "step $2 of $1 is '$p', not $3, after ${t}s"
}

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Create the release settings"
kubectl create configmap release-settings -n "$NS" \
  --from-literal=channel=canary --from-literal=owners='bob, alice' \
  --dry-run=client -o yaml | kubectl apply -f -

step "Apply the Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: release-gate
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  components:
    - name: web
      type: webservice
      properties:
        image: nginx:1.27
  workflow:
    steps:
      - name: settings
        type: read-object
        properties:
          apiVersion: v1
          kind: ConfigMap
          name: release-settings
          namespace: '$(context.namespace)'
        outputs:
          - name: channel
            valueFrom: output.$returns.value.data.channel
          - name: owners
            valueFrom: output.$returns.value.data.owners
      - name: deploy
        type: apply-component
        properties:
          component: web
      - name: canary-note
        type: print-message-in-status
        if: '$(steps.settings.outputs.channel == "canary")'
        properties:
          message: canary release, watch the dashboards
      - name: summary
        type: print-message-in-status
        if: '$(steps.deploy.succeeded)'
        properties:
          message: '$(context.appName) on $(steps.settings.outputs.channel.upperAscii()), owners: $(steps.settings.outputs.owners.split(",").map(o, o.trim()).sort().join(" & "))'
EOF

step "Wait for it to run"
wait_app release-gate "$NS"
vela status release-gate -n "$NS"

step "Check the canary run"
expect "canary-note phase" "succeeded" "$(step_field release-gate canary-note phase)"
expect "summary message" "release-gate on CANARY, owners: alice & bob" "$(step_field release-gate summary message)"

step "Switch to stable and rerun the workflow"
kubectl patch configmap release-settings -n "$NS" -p '{"data":{"channel":"stable"}}'
vela workflow restart release-gate -n "$NS"
wait_step release-gate summary succeeded
wait_app release-gate "$NS"

step "Check the stable run"
expect "canary-note phase" "skipped" "$(step_field release-gate canary-note phase)"
expect "summary message" "release-gate on STABLE, owners: alice & bob" "$(step_field release-gate summary message)"

echo
echo "PASS: A workflow gated on an earlier step's outputs"
