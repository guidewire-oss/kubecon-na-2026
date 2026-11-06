#!/usr/bin/env bash
# KubeVela 1.12 demo: Test a trait's patch and its health
# A scaler trait patches replicas and adds an HPA; the cases check the patch, then health against an observed HPA status.
#
# Needs: the vela CLI 1.12. No cluster: vela def test runs locally.
#
#   ./02-trait-render-status.sh            run the demo and check the result
#   ./02-trait-render-status.sh --cleanup  nothing to remove; files live in a temp directory
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

step "Write the trait and its tests"
cat > scaler.cue <<'EOF'
scaler: {
	type: "trait"
	attributes: {
		appliesToWorkloads: ["deployments.apps"]
		status: healthPolicy: #"""
			isHealth: context.outputs.hpa.status.currentReplicas >= parameter.replicas
			"""#
	}
}
template: {
	patch: spec: replicas: parameter.replicas
	outputs: hpa: {
		apiVersion: "autoscaling/v2"
		kind:       "HorizontalPodAutoscaler"
		metadata: name: context.name
	}
	parameter: replicas: *1 | int
}
EOF
cat > scaler_test.cue <<'EOF'
import "vela/test"

_scaler: {
	definition: "scaler"
	context: name: "shop"
	workload: {
		apiVersion: "apps/v1"
		kind:       "Deployment"
		metadata: name: "shop"
		spec: template: spec: containers: [{name: "shop", image: "nginx:1.25"}]
	}
}

"patches the workload's replicas": test.#TraitRender & _scaler & {
	parameter: replicas: 3
	expect: {
		output: spec: replicas: 3
		outputs: hpa: {kind: "HorizontalPodAutoscaler", metadata: name: "shop"}
	}
}

"healthy once the autoscaler reaches the replicas": test.#TraitStatus & _scaler & {
	parameter: replicas: 3
	observed: outputs: hpa: status: currentReplicas: 3
	expect: healthy: true
}

"not healthy below them": test.#TraitStatus & _scaler & {
	parameter: replicas: 3
	observed: outputs: hpa: status: currentReplicas: 2
	expect: healthy: false
}
EOF

step "Run them, listing each case"
run_tests 0 "3 passed, 0 failed" . -v

step "JSON for CI: one object per case"
json=$(vela def test . --json)
echo "$json"
expect_count=$(printf '%s\n' "$json" | grep -c '"passed": true' || true)
[ "$expect_count" = 3 ] || fail "--json: expected 3 passing cases, got $expect_count"
echo "ok: --json reports 3 passing cases"

step "Only the status cases"
run_tests 0 "2 passed, 0 failed, 1 skipped" . --label-filter status

echo
echo "PASS: Test a trait's patch and its health"
