#!/usr/bin/env bash
# KubeVela 1.12 demo: A loop that fails part-way, then restart --step
# One team namespace is missing on purpose: that item fails and the item after it is skipped; once the namespace exists, restarting from the failed item reruns it and everything after it.
#
# Needs: KubeVela 1.12 (no feature gate), and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./06-failure-and-restart.sh            run the demo and check the result
#   ./06-failure-and-restart.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-loops-6
TEAMS="demo-loops-6-team-a demo-loops-6-team-b demo-loops-6-team-c"

cleanup() {
  # shellcheck disable=SC2086
  kubectl delete namespace "$NS" $TEAMS --ignore-not-found --wait=false
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
loop() { kubectl get app team-quotas -n "$NS" -o jsonpath="{.status.workflow.steps[?(@.name==\"quota\")].$1}"; }
items() { kubectl get app team-quotas -n "$NS" -o jsonpath='{range .status.workflow.steps[?(@.name=="quota")].subSteps[*]}{.name}={.phase} {end}'; }

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Create team-a and team-c; team-b is left out on purpose"
kubectl delete namespace demo-loops-6-team-b --ignore-not-found --wait=true >/dev/null
for t in demo-loops-6-team-a demo-loops-6-team-c; do
  kubectl create namespace "$t" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

step "Apply the Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: team-quotas
spec:
  components: []
  workflow:
    steps:
      - name: quota
        type: apply-object
        forEach:
          items: [demo-loops-6-team-a, demo-loops-6-team-b, demo-loops-6-team-c]
          mode: StepByStep
        inputs:
          - from: each.item
            parameterKey: value.metadata.namespace
        properties:
          value:
            apiVersion: v1
            kind: ResourceQuota
            metadata:
              name: team-quota
            spec:
              hard:
                pods: "10"
EOF

step "Wait for team-b's item to fail"
echo "note: an apply error is retried with backoff (10 times by default), so this takes a couple of minutes"
p=""
for _ in $(seq 1 72); do
  p=$(loop phase)
  [ "$p" = failed ] && break
  sleep 5
done
[ "$p" = failed ] || { vela status team-quotas -n "$NS" || true; fail "loop is '$p', not failed, after 6m"; }
echo "loop message: $(loop message)"
expect "items after the failure" "quota-0=succeeded quota-1=failed quota-2=skipped " "$(items)"
case "$(loop message)" in
  "item 1 (demo-loops-6-team-b) failed"*) echo "ok: loop message names item 1" ;;
  *) fail "loop message does not name item 1: $(loop message)" ;;
esac

step "Fix the cause, then restart from the failed item"
kubectl create namespace demo-loops-6-team-b
vela workflow restart team-quotas -n "$NS" --step quota-1
wait_app team-quotas "$NS"

step "Check the result"
expect "items after the restart" "quota-0=succeeded quota-1=succeeded quota-2=succeeded " "$(items)"
for t in $TEAMS; do
  expect "quota in $t" "10" "$(kubectl get resourcequota team-quota -n "$t" -o jsonpath='{.spec.hard.pods}')"
done

echo
echo "PASS: A loop that fails part-way, then restart --step"
