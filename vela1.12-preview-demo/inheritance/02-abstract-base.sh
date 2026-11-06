#!/usr/bin/env bash
# KubeVela 1.12 demo: An abstract base for the platform's rules
# acme-base adds a cost-centre label and is marked abstract, so Applications are refused it; acme-web extends it and works.
#
# Needs: featureGates.enableDefinitionInheritance=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./02-abstract-base.sh            run the demo and check the result
#   ./02-abstract-base.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-inheritance-2

cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  # children before the parent they extend
  kubectl delete componentdefinition acme-web -n vela-system --ignore-not-found
  kubectl delete componentdefinition acme-base -n vela-system --ignore-not-found
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

step "Write and apply the abstract base, then the definition built on it"
cat > acme-base.cue <<'EOF'
"acme-base": {
	type:     "component"
	extends:  "webservice"
	abstract: true
	attributes: {}
}
template: {
	$super: properties: {
		image: parameter.image
		cpu:   "500m"
	}
	output: metadata: labels: "acme.com/cost-centre": parameter.costCentre
	parameter: {
		image:      string
		costCentre: string
	}
}
EOF
cat > acme-web.cue <<'EOF'
"acme-web": {
	type:    "component"
	extends: "acme-base"
	attributes: {}
}
template: {
	$super: properties: {
		image:      parameter.image
		costCentre: "web-platform"
	}
	parameter: image: string
}
EOF
vela def apply acme-base.cue -n vela-system
vela def apply acme-web.cue -n vela-system

step "An Application naming the abstract base is refused at admission"
if out=$(kubectl apply -n "$NS" -f - 2>&1 <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: direct
spec:
  components:
    - name: direct
      type: acme-base
      properties:
        image: nginx:1.27
        costCentre: finance
EOF
); then
  fail "an Application of type acme-base was admitted: $out"
fi
echo "$out"
case "$out" in
  *"abstract and cannot be used directly"*) echo "ok: refused, naming the abstract type" ;;
  *) fail "refused, but not for being abstract: $out" ;;
esac

step "One naming acme-web is accepted"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: storefront
spec:
  components:
    - name: storefront
      type: acme-web
      properties:
        image: nginx:1.27
EOF
wait_app storefront "$NS"

step "Check the result"
kubectl get deploy storefront -n "$NS" --show-labels
expect "cost-centre label (from acme-base)" "web-platform" "$(kubectl get deploy storefront -n "$NS" -o jsonpath='{.metadata.labels.acme\.com/cost-centre}')"
expect "cpu (from acme-base)" "500m" "$(kubectl get deploy storefront -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')"
expect "image (through both levels)" "nginx:1.27" "$(kubectl get deploy storefront -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')"
expect "no Application of type acme-base" "" "$(kubectl get app direct -n "$NS" -o name --ignore-not-found)"

echo
echo "PASS: An abstract base for the platform's rules"
