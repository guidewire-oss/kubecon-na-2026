#!/usr/bin/env bash
# KubeVela 1.12 demo: Migrate legacy configs
# A legacy config-template-* ConfigMap and its config Secret are adopted into ConfigTemplate and Config CRs; nothing is deleted, and a second run skips what is done.
#
# Needs: KubeVela 1.12 with the configs.config.oam.dev and configtemplates.config.oam.dev CRDs, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./04-migrate-legacy.sh            run the demo and check the result
#   ./04-migrate-legacy.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-configs-4

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
  local what=$1 want=$2 got=""
  shift 2
  for _ in $(seq 1 24); do
    got=$("$@" 2>/dev/null || true)
    [ "$got" = "$want" ] && { echo "ok: $what = $got"; return 0; }
    sleep 5
  done
  fail "$what: expected '$want', got '$got' after 120s"
}

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Set up a legacy template and config, as 1.11 stored them"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-template-image-registry
  labels:
    config.oam.dev/catalog: velacore-config
    config.oam.dev/scope: project
  annotations:
    config.oam.dev/alias: Image registry
    config.oam.dev/description: Where images are pulled from
    config.oam.dev/sensitive: "false"
data:
  template: |
    metadata: {
    	name:        "image-registry"
    	alias:       "Image registry"
    	description: "Where images are pulled from"
    	scope:       "project"
    	sensitive:   false
    }
    template: {
    	output: {
    		type: "Opaque"
    		stringData: registry: parameter.registry
    	}
    	parameter: {
    		// +usage=The registry host
    		registry: string
    	}
    }
---
apiVersion: v1
kind: Secret
metadata:
  name: team-registry
  labels:
    config.oam.dev/catalog: velacore-config
    config.oam.dev/type: image-registry
    config.oam.dev/scope: project
  annotations:
    config.oam.dev/alias: Team registry
    config.oam.dev/sensitive: "false"
    config.oam.dev/template-namespace: demo-configs-4
type: Opaque
stringData:
  registry: registry.example.com
  input-properties: '{"registry":"registry.example.com"}'
EOF

step "Preview the migration"
vela config-template migrate --all -n "$NS" --dry-run
expect "dry run creates nothing" "" \
  "$(kubectl get configtemplates.config.oam.dev,configs.config.oam.dev -n "$NS" -o name)"

step "Migrate"
vela config-template migrate --all -n "$NS"

step "Check the CRs"
kubectl get configtemplates.config.oam.dev,configs.config.oam.dev -n "$NS"
wait_for "ConfigTemplate phase" "Available" kubectl get configtemplates.config.oam.dev image-registry -n "$NS" -o jsonpath='{.status.phase}'
wait_for "Config phase" "Available" kubectl get configs.config.oam.dev team-registry -n "$NS" -o jsonpath='{.status.phase}'
expect "Config templateRef" "image-registry" \
  "$(kubectl get configs.config.oam.dev team-registry -n "$NS" -o jsonpath='{.spec.templateRef.name}')"
expect "Config properties" '{"registry":"registry.example.com"}' \
  "$(kubectl get configs.config.oam.dev team-registry -n "$NS" -o jsonpath='{.spec.properties}')"
expect "legacy Secret kept, now owned by the Config" "Config/team-registry" \
  "$(kubectl get secret team-registry -n "$NS" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}')"
expect "legacy ConfigMap kept" "config-template-image-registry" \
  "$(kubectl get configmap config-template-image-registry -n "$NS" -o jsonpath='{.metadata.name}')"

step "A second run skips what is done"
vela config-template migrate --all -n "$NS"
vela config-template migrate image-registry -n "$NS"

echo
echo "PASS: Migrate legacy configs"
