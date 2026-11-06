#!/usr/bin/env bash
# KubeVela 1.12 demo: Values from a ConfigMap, upgraded on change
# The platform keeps the chart's values in a ConfigMap; editing it runs a helm upgrade with no change to the Application.
#
# Needs: KubeVela 1.11 or later (no feature gate), the vela CLI 1.12, and the helm CLI to look at the release.
# Runs against the cluster in your current kubeconfig.
#
#   ./02-values-from-configmap.sh            run the demo and check the result (up to about 6 minutes: it waits for a resync)
#   ./02-values-from-configmap.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-helm-2

cleanup() {
  kubectl delete app podinfo-managed -n "$NS" --ignore-not-found   # uninstalls the Helm release
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
uimsg() { kubectl get deploy podinfo-managed -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PODINFO_UI_MESSAGE")].value}'; }

kubectl wait --for=delete namespace/"$NS" --timeout=120s >/dev/null 2>&1 || true
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "The platform's values"
kubectl create configmap podinfo-values -n "$NS" --from-literal=values.yaml='replicaCount: 2
ui:
  message: "Hello from KubeVela"' --dry-run=client -o yaml | kubectl apply -f -

step "Apply the Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: podinfo-managed
spec:
  components:
    - name: podinfo-managed
      type: helmchart
      properties:
        chart:
          source: oci://ghcr.io/stefanprodan/charts/podinfo
          version: "6.7.1"
        valuesFrom:
          - kind: ConfigMap
            name: podinfo-values      # key defaults to values.yaml
        values:
          ui:
            color: "#0b6e8a"           # inline values override valuesFrom
        options:
          atomic: true
          timeout: 5m
EOF

step "Wait for it to run"
wait_app podinfo-managed "$NS"
helm history podinfo-managed -n "$NS"

step "Check the first install"
expect "replicas from valuesFrom" "2" "$(kubectl get deploy podinfo-managed -n "$NS" -o jsonpath='{.spec.replicas}')"
expect "message from valuesFrom" "Hello from KubeVela" "$(uimsg)"
expect "colour from inline values" "#0b6e8a" \
  "$(kubectl get deploy podinfo-managed -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PODINFO_UI_COLOR")].value}')"
rev1=$(helm history podinfo-managed -n "$NS" -o json | jq 'length')

step "Edit the values"
kubectl patch configmap podinfo-values -n "$NS" --type merge \
  -p '{"data":{"values.yaml":"replicaCount: 3\nui:\n  message: Upgraded"}}'
echo "note: the change is noticed at the next reconcile, and the Application resyncs every 5 minutes"
wait_for "message after upgrade" "Upgraded" 420 uimsg
wait_for "replicas after upgrade" "3" 60 kubectl get deploy podinfo-managed -n "$NS" -o jsonpath='{.spec.replicas}'
helm history podinfo-managed -n "$NS"
rev2=$(helm history podinfo-managed -n "$NS" -o json | jq 'length')
[ "$rev2" -gt "$rev1" ] || fail "no new Helm revision: $rev1 then $rev2"
echo "ok: Helm revisions $rev1 -> $rev2"

echo
echo "PASS: Values from a ConfigMap, upgraded on change"
