#!/usr/bin/env bash
# KubeVela 1.12 demo: A template and a Config, as YAML
# A feature-flags ConfigTemplate that renders a ConfigMap, and a Config that fills it in.
#
# Needs: KubeVela 1.12 with the configs.config.oam.dev and configtemplates.config.oam.dev CRDs, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./01-template-and-config.sh            run the demo and check the result
#   ./01-template-and-config.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-configs-1

cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
}
if [ "${1:-}" = "--cleanup" ]; then cleanup; exit 0; fi

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# expect <description> <expected> <actual>
expect() { [ "$2" = "$3" ] || fail "$1: expected '$2', got '$3'"; echo "ok: $1 = $3"; }
# wait_for <description> <expected> <command...>: until the command prints the expected value
wait_for() {
  local what=$1 want=$2 got="" t
  shift 2
  for t in $(seq 1 36); do
    got=$("$@" 2>/dev/null || true)
    [ "$got" = "$want" ] && { echo "ok: $what = $got"; return 0; }
    sleep 5
  done
  fail "$what: expected '$want', got '$got' after 180s"
}

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Apply the ConfigTemplate and the Config"
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
    namespace: demo-configs-1
  properties:
    flags:
      expressCheckout: true
      giftCards: false
EOF

step "Wait for the Config to render"
wait_for "Config phase" "Available" kubectl get configs.config.oam.dev checkout-flags -n "$NS" -o jsonpath='{.status.phase}'
kubectl get configtemplates.config.oam.dev,configs.config.oam.dev -n "$NS"

step "Check the result"
kubectl get configmap checkout-flags -n "$NS" -o yaml
expect "rendered ConfigMap data" '{"expressCheckout":"true","giftCards":"false"}' \
  "$(kubectl get configmap checkout-flags -n "$NS" -o jsonpath='{.data}')"
secret=$(kubectl get configs.config.oam.dev checkout-flags -n "$NS" -o jsonpath='{.status.secretRef.name}')
[ -n "$secret" ] || fail "Config has no status.secretRef"
kubectl get secret "$secret" -n "$NS" >/dev/null && echo "ok: Config wrote Secret $secret"

echo
echo "PASS: A template and a Config, as YAML"
