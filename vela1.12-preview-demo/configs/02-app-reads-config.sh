#!/usr/bin/env bash
# KubeVela 1.12 demo: An Application reads a Config
# The vela-config source reads a Config's properties, so an app follows the flags without copying them, and autoUpdate rolls a change out.
#
# Needs: featureGates.enableCelExpressions=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./02-app-reads-config.sh            run the demo and check the result
#   ./02-app-reads-config.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-configs-2

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
# wait_for <description> <expected> <timeout seconds> <command...>: until the command prints the expected value
wait_for() {
  local what=$1 want=$2 t=$3 got=""
  shift 3
  for _ in $(seq 1 $((t / 5))); do
    got=$("$@" 2>/dev/null || true)
    [ "$got" = "$want" ] && { echo "ok: $what = $got"; return 0; }
    sleep 5
  done
  fail "$what: expected '$want', got '$got' after ${t}s"
}
express() {
  kubectl get deploy checkout -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EXPRESS_CHECKOUT")].value}'
}

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Prerequisite: the feature-flags template and the checkout-flags Config (Example 1)"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: config.oam.dev/v1alpha1
kind: ConfigTemplate
metadata:
  name: feature-flags
spec:
  scope: namespace
  template: |
    metadata: {
    	name:        "feature-flags"
    	alias:       "Feature flags"
    	description: "Flags services read at start-up"
    	scope:       "project"
    }
    template: {
    	outputs: flags: {
    		apiVersion: "v1"
    		kind:       "ConfigMap"
    		metadata: name: context.name
    		data: {for k, v in parameter.flags {"\(k)": "\(v)"}}
    	}
    	parameter: {
    		// +usage=Flag names and whether each is on
    		flags: [string]: bool
    	}
    }
---
apiVersion: config.oam.dev/v1alpha1
kind: Config
metadata:
  name: checkout-flags
spec:
  alias: Checkout flags
  description: Flags for the checkout service
  templateRef:
    name: feature-flags
    namespace: demo-configs-2
  properties:
    flags:
      expressCheckout: true
      giftCards: false
EOF
wait_for "Config phase" "Available" 120 kubectl get configs.config.oam.dev checkout-flags -n "$NS" -o jsonpath='{.status.phase}'

step "Apply the Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: checkout
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  sources:
    - name: flags
      type: vela-config
      properties:
        name: checkout-flags
        namespace: demo-configs-2
      autoUpdate: true
  components:
    - name: checkout
      type: webservice
      properties:
        image: nginx:1.27
        env:
          - name: EXPRESS_CHECKOUT
            value: '$(string(source.flags.properties.flags.expressCheckout))'
EOF

step "Wait for it to run"
wait_app checkout "$NS"
expect "EXPRESS_CHECKOUT" "true" "$(express)"

step "Turn the flag off in the Config"
kubectl patch configs.config.oam.dev checkout-flags -n "$NS" --type merge \
  -p '{"spec":{"properties":{"flags":{"expressCheckout":false,"giftCards":false}}}}'
echo "note: vela-config caches its value for up to 5 minutes; autoUpdate re-dispatches once the cache refreshes"
wait_for "EXPRESS_CHECKOUT after the change" "false" 420 express
vela status checkout -n "$NS" --sources

echo
echo "PASS: An Application reads a Config"
