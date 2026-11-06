#!/usr/bin/env bash
# KubeVela 1.12 demo: A custom source with a typed contract
# A SourceDefinition of your own publishes typed, constrained fields, so consumers read $(source.platform.replicas) with no guard and no int().
#
# Needs: featureGates.enableCelExpressions=true and featureGates.enableSourceAutoUpdate=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./03-custom-typed-source.sh            run the demo and check the result (about 7 minutes: it waits for the next resync)
#   ./03-custom-typed-source.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-sources-3
DATA_NS=acme-system   # where the definition reads its ConfigMap; fixed in the definition

cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  kubectl delete namespace "$DATA_NS" --ignore-not-found --wait=false
  kubectl delete sourcedefinition acme-platform -n vela-system --ignore-not-found
  kubectl delete secret -n vela-system -l sourcedefinition.oam.dev/name=acme-platform --ignore-not-found
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
phase() { kubectl get app storefront -n "$NS" -o jsonpath='{.status.sources[0].phase}'; }

kubectl wait --for=delete namespace/"$NS" namespace/"$DATA_NS" --timeout=120s >/dev/null 2>&1 || true
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

step "Write the definition, acme-platform.cue"
cat > acme-platform.cue <<'EOF'
import (
	"vela/kube"
	"strconv"
)

"acme-platform": {
	type:        "source"
	description: "The registry, replica count and tier this cluster runs with"
	attributes: {}
}

template: {
	schema: {
		registry: string
		replicas: int
		tier:     "gold" | "silver" | "bronze"
	}

	storage: {
		storageTTL:     "1m"
		onStaleFailure: "use-stale"
	}

	// Parameterless: where the settings live is the platform's business.
	parameter: {}

	_cm: kube.#Get & {
		$params: {
			cluster: context.cluster
			resource: {
				apiVersion: "v1"
				kind:       "ConfigMap"
				metadata: {
					name:      "acme-platform"
					namespace: "acme-system"
				}
			}
		}
	}
	_data: _cm.$returns.data

	output: {
		registry: _data.registry
		replicas: strconv.Atoi(_data.replicas)   // convert once, here
		tier:     _data.tier
	}
}
EOF

step "Apply it and look at it the way consumers will"
vela def apply acme-platform.cue -n vela-system
vela def show acme-platform

step "Create the platform's data"
kubectl create namespace acme-system
kubectl create configmap acme-platform -n acme-system \
  --from-literal=registry=docker.io/library \
  --from-literal=replicas=3 \
  --from-literal=tier=gold

step "Bind it"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: storefront
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  sources:
    - name: platform
      type: acme-platform
      autoUpdate: true
  components:
    - name: storefront
      type: webservice
      properties:
        image: "$(source.platform.registry)/nginx:1.27"
        labels:
          acme.com/tier: "$(source.platform.tier)"
      traits:
        - type: scaler
          properties:
            replicas: "$(source.platform.replicas)"
EOF
wait_app storefront "$NS"
vela status storefront -n "$NS" --sources

step "Check the result"
wait_for "replicas" "3" 60 kubectl get deploy storefront -n "$NS" -o jsonpath='{.spec.replicas}'
expect "image" "docker.io/library/nginx:1.27" \
  "$(kubectl get deploy storefront -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')"
expect "tier label" "gold" \
  "$(kubectl get deploy storefront -n "$NS" -o jsonpath='{.spec.template.metadata.labels.acme\.com/tier}')"

step "A read of an undeclared field is refused at apply"
if out=$(kubectl apply -n "$NS" --dry-run=server -f - 2>&1 <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: storefront-region
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  sources:
    - name: platform
      type: acme-platform
  components:
    - name: web
      type: webservice
      properties:
        image: nginx:1.27
        env:
          - name: REGION
            value: "$(source.platform.region)"
EOF
); then fail "an undeclared field was admitted"; fi
echo "$out" | grep -o 'path "region".*' | head -1
echo "$out" | grep -q 'is not declared in schema' || fail "unexpected refusal: $out"
echo "ok: refused"

step "Break the contract"
kubectl patch configmap acme-platform -n acme-system -p '{"data":{"tier":"platinum"}}'
echo "note: the 1m cache entry is re-read at the first reconcile after it expires, and the Application resyncs every 5 minutes"
wait_for "binding phase" "Stale" 420 phase
vela status storefront -n "$NS" --sources
expect "still serving the last good tier" "gold" \
  "$(kubectl get deploy storefront -n "$NS" -o jsonpath='{.spec.template.metadata.labels.acme\.com/tier}')"
expect "app still running" "running" "$(kubectl get app storefront -n "$NS" -o jsonpath='{.status.status}')"

echo
echo "PASS: A custom source with a typed contract"
