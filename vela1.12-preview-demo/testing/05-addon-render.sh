#!/usr/bin/env bash
# KubeVela 1.12 demo: Test what enabling an addon installs
# #AddonRender renders a local addon as vela addon enable would: its components, how its parameters reach them, the definitions it ships, and what it rejects.
#
# Needs: the vela CLI 1.12. No cluster: vela def test runs locally.
#
#   ./05-addon-render.sh            run the demo and check the result
#   ./05-addon-render.sh --cleanup  nothing to remove; files live in a temp directory
set -euo pipefail

if [ "${1:-}" = "--cleanup" ]; then exit 0; fi

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# run_tests <expected exit code> <expected summary line> [vela def test args...]
run_tests() {
  local want_code=$1 want_summary=$2 out code=0
  shift 2
  echo "$ vela def test $*"
  out=$(vela def test "$@" 2>&1) || code=$?
  echo "$out"
  [ "$code" = "$want_code" ] || fail "vela def test $*: exit code $code, expected $want_code"
  printf '%s\n' "$out" | grep -qxF "$want_summary" || fail "vela def test $*: no summary line '$want_summary'"
  echo "ok: exit $code, '$want_summary'"
}

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cd "$DIR"

step "Write the addon and its tests"
mkdir -p shop/resources shop/definitions
cat > shop/metadata.yaml <<'EOF'
name: shop
version: 1.2.0
description: A test addon
deployTo:
  control_plane: true
  runtime_cluster: false
EOF
cat > shop/parameter.cue <<'EOF'
parameter: {
	image:       *"shop:1.0" | string
	replicas:    *1 | int
	serviceType: *"ClusterIP" | "NodePort" | "LoadBalancer"
}
EOF
cat > shop/template.cue <<'EOF'
output: {
	apiVersion: "core.oam.dev/v1beta1"
	kind:       "Application"
	spec: components: [{
		name: "web"
		type: "shop-web"
		properties: {image: parameter.image, replicas: parameter.replicas}
	}]
}
EOF
cat > shop/resources/svc.cue <<'EOF'
output: {
	type: "raw"
	properties: {
		apiVersion: "v1"
		kind:       "Service"
		metadata: {
			name:      "shop"
			namespace: "vela-system"
			labels: version: context.metadata.version
		}
		spec: type: parameter.serviceType
	}
}
EOF
cat > shop/definitions/shop-web.cue <<'EOF'
"shop-web": {
	type: "component"
	attributes: workload: definition: {
		apiVersion: "apps/v1"
		kind:       "Deployment"
	}
}
template: {
	output: {
		apiVersion: "apps/v1"
		kind:       "Deployment"
		spec: {
			replicas: parameter.replicas
			template: spec: containers: [{name: context.name, image: parameter.image}]
		}
	}
	parameter: {
		image:    string
		replicas: *1 | int
	}
}
EOF
cat > shop/shop_test.cue <<'EOF'
import "vela/test"

"enables with defaults": test.#AddonRender & {
	addon: "."
	expect: {
		application: kind: "Application"
		components: {
			web: {type: "shop-web", properties: {image: "shop:1.0", replicas: 1}}
			svc: properties: {
				kind: "Service"
				metadata: labels: version: "1.2.0"
				spec: type: "ClusterIP"
			}
		}
		definitions: ComponentDefinition: "shop-web": kind: "ComponentDefinition"
	}
}

"parameters reach the components": test.#AddonRender & {
	addon: "."
	parameter: {image: "shop:2.0", serviceType: "NodePort"}
	expect: components: {
		web: properties: image: "shop:2.0"
		svc: properties: spec: type: "NodePort"
	}
}

"rejects a parameter the addon does not allow": test.#AddonRender & {
	addon: "."
	parameter: serviceType: "Nope"
	expect: error: =~"parameter.serviceType"
}
EOF

step "Run them; no cluster is needed"
run_tests 0 "3 passed, 0 failed" shop -v

echo
echo "PASS: Test what enabling an addon installs"
