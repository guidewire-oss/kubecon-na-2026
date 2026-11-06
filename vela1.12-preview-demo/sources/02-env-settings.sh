#!/usr/bin/env bash
# KubeVela 1.12 demo: Settings from the environment
# One Application, applied to two namespaces labelled differently, renders differently in each by reading its namespace with vela-env.
#
# Needs: featureGates.enableCelExpressions=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./02-env-settings.sh            run the demo and check the result
#   ./02-env-settings.sh --cleanup  remove everything it created
set -euo pipefail

DEV=demo-sources-2-dev
PROD=demo-sources-2-prod

cleanup() {
  kubectl delete namespace "$DEV" "$PROD" --ignore-not-found --wait=false
  kubectl delete secret -n vela-system -l sourcedefinition.oam.dev/ctx.namespace="$DEV" --ignore-not-found
  kubectl delete secret -n vela-system -l sourcedefinition.oam.dev/ctx.namespace="$PROD" --ignore-not-found
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
envvar() { kubectl get deploy web -n "$1" -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$2\")].value}"; }

kubectl wait --for=delete namespace/"$DEV" namespace/"$PROD" --timeout=120s >/dev/null 2>&1 || true

step "Label two namespaces differently"
kubectl create namespace "$DEV" && kubectl label namespace "$DEV" tier=dev
kubectl create namespace "$PROD" && kubectl label namespace "$PROD" tier=prod

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/env-aware.yaml" <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: env-aware
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  sources:
    - name: env
      type: vela-env
  components:
    - name: web
      type: webservice
      properties:
        image: nginx:1.27
        env:
          - name: TIER
            value: '$(has(source.env.labels.tier) ? source.env.labels.tier : "unknown")'
          - name: NAMESPACE
            value: '$(source.env.namespace)'
EOF

step "Apply the same file to both"
cd "$WORK"
vela up -f env-aware.yaml -n "$DEV"
vela up -f env-aware.yaml -n "$PROD"

step "Wait for both to run"
wait_app env-aware "$DEV"
wait_app env-aware "$PROD"

step "Check the result"
expect "TIER in $DEV" "dev" "$(envvar "$DEV" TIER)"
expect "TIER in $PROD" "prod" "$(envvar "$PROD" TIER)"
expect "NAMESPACE in $PROD" "$PROD" "$(envvar "$PROD" NAMESPACE)"
vela status env-aware -n "$PROD" --sources

echo
echo "PASS: Settings from the environment"
