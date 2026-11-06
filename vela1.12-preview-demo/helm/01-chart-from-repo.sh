#!/usr/bin/env bash
# KubeVela 1.12 demo: A chart from a repository
# podinfo from its Helm repository with inline values and a health check, installed as a real Helm release without FluxCD.
#
# Needs: KubeVela 1.11 or later (no feature gate), the vela CLI 1.12, and the helm CLI to look at the release.
# Runs against the cluster in your current kubeconfig.
#
#   ./01-chart-from-repo.sh            run the demo and check the result
#   ./01-chart-from-repo.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-helm-1

cleanup() {
  kubectl delete app podinfo -n "$NS" --ignore-not-found   # uninstalls the Helm release
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

kubectl wait --for=delete namespace/"$NS" --timeout=120s >/dev/null 2>&1 || true
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Apply the Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: podinfo
spec:
  components:
    - name: podinfo
      type: helmchart
      properties:
        chart:
          source: podinfo
          repoURL: https://stefanprodan.github.io/podinfo
          version: "6.7.1"
          # or as OCI: source: oci://ghcr.io/stefanprodan/charts/podinfo
        values:
          replicaCount: 2
        healthStatus:
          - resource:
              kind: Deployment
            condition:
              type: Available
EOF

step "Wait for it to run"
wait_app podinfo "$NS"
vela status podinfo -n "$NS"
helm list -n "$NS"
helm history podinfo -n "$NS"

step "Check the result"
expect "Helm release status" "deployed" \
  "$(helm list -n "$NS" -o json | jq -r '.[] | select(.name=="podinfo") | .status')"
expect "chart" "podinfo-6.7.1" "$(helm list -n "$NS" -o json | jq -r '.[] | select(.name=="podinfo") | .chart')"
expect "replicas from values" "2" "$(kubectl get deploy podinfo -n "$NS" -o jsonpath='{.spec.replicas}')"
expect "Deployment Available" "True" \
  "$(kubectl get deploy podinfo -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"

echo
echo "PASS: A chart from a repository"
