#!/usr/bin/env bash
# KubeVela 1.12 demo: A workflow writes a Config
# The create-config step now writes a Config CR, so a release workflow can publish facts other Applications read.
#
# Needs: KubeVela 1.12 with the configs.config.oam.dev CRD, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./03-workflow-writes-config.sh            run the demo and check the result
#   ./03-workflow-writes-config.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-configs-3

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
  name: release
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
      - name: publish-release
        type: create-config
        properties:
          name: release-info
          config:
            version: "1.27"
            channel: stable
EOF

step "Wait for it to run"
wait_app release "$NS"

step "Check the result"
kubectl get configs.config.oam.dev release-info -n "$NS" -o yaml
expect "Config properties" '{"channel":"stable","version":"1.27"}' \
  "$(kubectl get configs.config.oam.dev release-info -n "$NS" -o jsonpath='{.spec.properties}')"
expect "owned by the Application" "release" \
  "$(kubectl get configs.config.oam.dev release-info -n "$NS" -o jsonpath='{.metadata.labels.app\.oam\.dev/name}')"
expect "vela config can read it back" "true" \
  "$(vela config list -n "$NS" 2>/dev/null | grep -q release-info && echo true || echo false)"

echo
echo "PASS: A workflow writes a Config"
