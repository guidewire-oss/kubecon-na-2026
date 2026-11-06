#!/usr/bin/env bash
# KubeVela 1.12 demo: Composing health and status with the parent
# available-web adds a health condition to webservice's and extends its status line; tolerant-web takes health over and builds on webservice's verdict.
#
# Needs: featureGates.enableDefinitionInheritance=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig. The tolerant-web part
# assumes a single-node cluster (such as k3d), where pods that refuse to share a
# node leave all but one replica Pending.
#
#   ./04-health-status.sh            run the demo and check the result
#   ./04-health-status.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-inheritance-4

cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  kubectl delete componentdefinition available-web tolerant-web -n vela-system --ignore-not-found
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
# wait_service <app> <namespace> <healthy> <message> [timeout seconds]: until the
# first component reports this health and status message
wait_service() {
  local app=$1 ns=$2 h=$3 m=$4 t=${5:-180} got=""
  for _ in $(seq 1 $((t / 5))); do
    got=$(kubectl get app "$app" -n "$ns" -o jsonpath='{.status.services[0].healthy}|{.status.services[0].message}' 2>/dev/null || true)
    [ "$got" = "$h|$m" ] && { echo "ok: $app healthy=$h, message '$m'"; return 0; }
    sleep 5
  done
  fail "$app: expected healthy=$h and message '$m', got '$got'"
}

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cd "$DIR"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Write and apply the two children of webservice"
cat > available-web.cue <<'EOF'
"available-web": {
	type:        "component"
	extends:     "webservice"
	description: "A webservice that is healthy only once every replica is available"
	attributes: status: {
		healthPolicy: #"""
			_available: *0 | int
			if context.output.status.availableReplicas != _|_ {
				_available: context.output.status.availableReplicas
			}
			isHealth: _available == context.output.spec.replicas
			"""#
		customStatus: #"""
			_available: *0 | int
			if context.output.status.availableReplicas != _|_ {
				_available: context.output.status.availableReplicas
			}
			message: "\($super.message), Available:\(_available)"
			"""#
	}
}
template: {
	$super: properties: {image: parameter.image, cpu: parameter.cpu}

	parameter: {
		image: string
		cpu:   *"250m" | string
	}
}
EOF
cat > tolerant-web.cue <<'EOF'
"tolerant-web": {
	type:        "component"
	extends:     "webservice"
	description: "A webservice that stays healthy while at least one replica is ready"
	attributes: status: healthPolicy: #"""
		$inherit: false
		_ready: *0 | int
		if context.output.status.readyReplicas != _|_ {
			_ready: context.output.status.readyReplicas
		}
		isHealth: $super.isHealth || _ready > 0
		"""#
}
template: {
	$super: properties: image: parameter.image

	parameter: image: string
}
EOF
vela def apply available-web.cue -n vela-system
vela def apply tolerant-web.cue -n vela-system

step "available-web: both policies hold, and the message extends webservice's"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: available
spec:
  components:
    - name: available
      type: available-web
      properties:
        image: nginx:1.27
EOF
wait_app available "$NS"
wait_service available "$NS" true "Ready:1/1, Available:1"

step "tolerant-web and plain webservice, three replicas that refuse to share a node"
for t in tolerant-web webservice; do
  kubectl apply -n "$NS" -f - <<EOF
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: $t
spec:
  components:
    - name: $t
      type: $t
      properties:
        image: nginx:1.27
      traits:
        - type: scaler
          properties:
            replicas: 3
        - type: affinity
          properties:
            podAntiAffinity:
              required:
                - topologyKey: kubernetes.io/hostname
                  labelSelector:
                    matchLabels:
                      app.oam.dev/component: $t
EOF
done

step "One replica of three is ready: tolerant-web is healthy, webservice is not"
wait_service tolerant-web "$NS" true "Ready:1/3"
wait_app tolerant-web "$NS"
wait_service webservice "$NS" false "Ready:1/3"
expect "Pending replicas of tolerant-web" "2" \
  "$(kubectl get pods -n "$NS" -l app.oam.dev/component=tolerant-web --field-selector=status.phase=Pending -o name | wc -l | tr -d ' ')"

echo
echo "PASS: Composing health and status with the parent"
