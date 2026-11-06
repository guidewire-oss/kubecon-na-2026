#!/usr/bin/env bash
# KubeVela 1.12 demo: Replacing the parent's workload, keeping the rest
# stateful-web turns off webservice's output with $inherit and builds a StatefulSet from $super.output, while webservice's Service still merges.
#
# Needs: featureGates.enableDefinitionInheritance=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./05-stateful-web.sh            run the demo and check the result
#   ./05-stateful-web.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-inheritance-5

cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  kubectl delete componentdefinition stateful-web -n vela-system --ignore-not-found
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

step "Write and apply the child definition"
cat > stateful-web.cue <<'EOF'
"stateful-web": {
	type:        "component"
	extends:     "webservice"
	description: "A webservice run as a StatefulSet, with a stable network identity"
	attributes: workload: definition: {
		apiVersion: "apps/v1"
		kind:       "StatefulSet"
	}
}
template: {
	// Replace the parent's workload; the Service in its outputs still merges.
	$inherit: {output: false}

	$super: properties: {
		image: parameter.image
		ports: [{port: parameter.port, expose: true}]
	}

	output: {
		apiVersion: "apps/v1"
		kind:       "StatefulSet"
		metadata: name: context.name
		spec: {
			serviceName: context.name
			replicas:    parameter.replicas
			selector:    $super.output.spec.selector
			template:    $super.output.spec.template
		}
	}

	parameter: {
		image:    string
		port:     *8080 | int
		replicas: *1 | int
	}
}
EOF
vela def apply stateful-web.cue -n vela-system

step "Apply an Application using it"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: shop
spec:
  components:
    - name: db
      type: stateful-web
      properties:
        image: nginx:1.27
        port: 80
        replicas: 2
EOF
wait_app shop "$NS"

step "Check the result"
kubectl get statefulset,service -n "$NS"
expect "no Deployment (webservice's output turned off)" "" "$(kubectl get deploy db -n "$NS" -o name --ignore-not-found)"
expect "StatefulSet replicas" "2" "$(kubectl get statefulset db -n "$NS" -o jsonpath='{.spec.replicas}')"
expect "StatefulSet ready replicas (webservice's health policy, inherited)" "2" "$(kubectl get statefulset db -n "$NS" -o jsonpath='{.status.readyReplicas}')"
expect "container port (from webservice's template)" "80" "$(kubectl get statefulset db -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].ports[0].containerPort}')"
expect "selector (from \$super.output)" "db" "$(kubectl get statefulset db -n "$NS" -o jsonpath='{.spec.selector.matchLabels.app\.oam\.dev/component}')"
expect "Service port (webservice's outputs, still merged)" "80" "$(kubectl get svc db -n "$NS" -o jsonpath='{.spec.ports[0].port}')"
expect "component health" "true" "$(kubectl get app shop -n "$NS" -o jsonpath='{.status.services[0].healthy}')"

echo
echo "PASS: Replacing the parent's workload, keeping the rest"
