#!/usr/bin/env bash
# KubeVela 1.12 demo: Feature flags reshaped with string and list functions
# A ConfigMap of loosely written flags becomes a clean sorted env var, a derived on/off switch, a normalised log level and an int replica count.
#
# Needs: featureGates.enableCelExpressions=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./04-flags-reshaped.sh            run the demo and check the result
#   ./04-flags-reshaped.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-cel-4

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

step "Create the flags ConfigMap"
kubectl create configmap app-flags -n "$NS" \
  --from-literal=features='search, checkout ,beta-ui' \
  --from-literal=logLevel=DEBUG \
  --from-literal=replicas=2 \
  --dry-run=client -o yaml | kubectl apply -f -

step "Apply the Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: flags-demo
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  sources:
    - name: flags
      type: configmap-local
      properties:
        name: app-flags
  components:
    - name: web
      type: webservice
      properties:
        image: nginx:1.27
        env:
          - name: FEATURES
            value: '$(has(source.flags.data.features) ? source.flags.data.features.split(",").map(f, f.trim()).filter(f, !f.startsWith("beta-")).sort().join(",") : "")'
          - name: BETA
            value: '$(has(source.flags.data.features) && source.flags.data.features.split(",").exists(f, f.trim().startsWith("beta-")) ? "on" : "off")'
          - name: LOG_LEVEL
            value: '$(has(source.flags.data.logLevel) ? source.flags.data.logLevel.lowerAscii() : "info")'
      traits:
        - type: scaler
          properties:
            replicas: '$("replicas" in source.flags.data ? int(source.flags.data.replicas) : 1)'
EOF

step "Wait for it to run"
wait_app flags-demo "$NS"

step "Check the result"
env_of() { kubectl get deploy web -n "$NS" -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}"; }
expect "FEATURES" "checkout,search" "$(env_of FEATURES)"
expect "BETA" "on" "$(env_of BETA)"
expect "LOG_LEVEL" "debug" "$(env_of LOG_LEVEL)"
expect "replicas" "2" "$(kubectl get deploy web -n "$NS" -o jsonpath='{.spec.replicas}')"

echo
echo "PASS: Feature flags reshaped with string and list functions"
