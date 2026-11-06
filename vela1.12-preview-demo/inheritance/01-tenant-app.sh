#!/usr/bin/env bash
# KubeVela 1.12 demo: A tenant webservice on top of webservice
# tenant-app extends the built-in webservice: teams give an image and a tenant, the platform fixes the port, resources and labels.
#
# Needs: featureGates.enableDefinitionInheritance=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./01-tenant-app.sh            run the demo and check the result
#   ./01-tenant-app.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-inheritance-1

cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  kubectl delete componentdefinition tenant-app -n vela-system --ignore-not-found
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
cat > tenant-app.cue <<'EOF'
"tenant-app": {
	type:        "component"
	extends:     "webservice"
	description: "A webservice owned by a tenant, with the platform's defaults applied."
	attributes: {}
}
template: {
	$super: properties: {
		image:  parameter.image
		cpu:    "250m"
		memory: "256Mi"
		ports: [{port: 8080, expose: true}]
	}
	output: metadata: labels: "tenant.oam.dev/name": parameter.tenant
	parameter: {
		// +usage=Container image
		image: string
		// +usage=Owning tenant
		tenant: string
	}
}
EOF
vela def apply tenant-app.cue -n vela-system
vela show tenant-app

step "Apply an Application naming only the child"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: shop
spec:
  components:
    - name: shop
      type: tenant-app
      properties:
        image: nginx:1.27
        tenant: team-a
EOF

step "Wait for it to run"
wait_app shop "$NS"

step "Check the result"
kubectl get deploy shop -n "$NS" --show-labels
expect "tenant label (from the child)" "team-a" "$(kubectl get deploy shop -n "$NS" -o jsonpath='{.metadata.labels.tenant\.oam\.dev/name}')"
expect "image (forwarded to webservice)" "nginx:1.27" "$(kubectl get deploy shop -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')"
expect "cpu (fixed by the child)" "250m" "$(kubectl get deploy shop -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')"
expect "memory (fixed by the child)" "256Mi" "$(kubectl get deploy shop -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}')"
expect "Service port (webservice's expose)" "8080" "$(kubectl get svc shop -n "$NS" -o jsonpath='{.spec.ports[0].port}')"

echo
echo "PASS: A tenant webservice on top of webservice"
