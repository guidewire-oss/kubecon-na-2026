#!/usr/bin/env bash
# KubeVela 1.12 demo: A trait that extends a trait
# ha-scaler builds on the built-in scaler: at least two replicas, plus a PodDisruptionBudget, with scaler's attributes and patch strategy inherited.
#
# Needs: featureGates.enableDefinitionInheritance=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./03-ha-scaler.sh            run the demo and check the result
#   ./03-ha-scaler.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-inheritance-3

cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  kubectl delete traitdefinition ha-scaler -n vela-system --ignore-not-found
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

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cd "$DIR"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Write and apply the child trait"
cat > ha-scaler.cue <<'EOF'
"ha-scaler": {
	type:        "trait"
	extends:     "scaler"
	description: "Runs two or more replicas, guarded by a PodDisruptionBudget"
}
template: {
	$super: properties: replicas: parameter.replicas

	outputs: pdb: {
		apiVersion: "policy/v1"
		kind:       "PodDisruptionBudget"
		metadata: name: context.name
		spec: {
			minAvailable: 1
			selector: matchLabels: "app.oam.dev/component": context.name
		}
	}

	parameter: {
		// +usage=Replicas to run, at least two
		replicas: *2 | int & >=2
	}
}
EOF
vela def apply ha-scaler.cue -n vela-system

step "Apply an Application using it"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: shop
spec:
  components:
    - name: shop
      type: webservice
      properties:
        image: nginx:1.27
      traits:
        - type: ha-scaler
EOF
wait_app shop "$NS"

step "Check the result"
expect "replicas (scaler's patch, ha-scaler's default)" "2" "$(kubectl get deploy shop -n "$NS" -o jsonpath='{.spec.replicas}')"
expect "PodDisruptionBudget (ha-scaler's own output)" "1" "$(kubectl get pdb shop -n "$NS" -o jsonpath='{.spec.minAvailable}')"

step "One replica is below ha-scaler's floor"
if out=$(kubectl apply -n "$NS" -f - 2>&1 <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: too-few
spec:
  components:
    - name: too-few
      type: webservice
      properties:
        image: nginx:1.27
      traits:
        - type: ha-scaler
          properties:
            replicas: 1
EOF
); then
  fail "an Application asking ha-scaler for one replica was admitted: $out"
fi
echo "$out"
case "$out" in
  *"what it supplies to scaler"*) echo "ok: refused at admission, naming what ha-scaler supplies to scaler" ;;
  *) fail "refused, but not by the chain: $out" ;;
esac

echo
echo "PASS: A trait that extends a trait"
