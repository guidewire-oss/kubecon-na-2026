#!/usr/bin/env bash
# KubeVela 1.12 demo: Test what a component renders
# A small component, web.cue, and two #ComponentRender cases in web_test.cue beside it.
#
# Needs: the vela CLI 1.12. No cluster: vela def test runs locally.
#
#   ./01-component-render.sh            run the demo and check the result
#   ./01-component-render.sh --cleanup  nothing to remove; files live in a temp directory
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

step "Write the component and its tests"
cat > web.cue <<'EOF'
web: {
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
		metadata: name: context.name
		spec: {
			replicas: parameter.replicas
			template: spec: containers: [{image: parameter.image}]
		}
	}
	parameter: {
		image:    string
		replicas: *1 | int
	}
}
EOF
cat > web_test.cue <<'EOF'
import "vela/test"

_web: {
	definition: "web"
	context: name: "shop"
}

"renders a Deployment from its parameters": test.#ComponentRender & _web & {
	parameter: {image: "nginx:1.25", replicas: 3}
	expect: output: {
		kind: "Deployment"
		metadata: name: "shop"
		spec: {
			replicas: 3
			template: spec: containers: [{image: "nginx:1.25"}]
		}
	}
}

"runs one replica by default": test.#ComponentRender & _web & {
	parameter: image: "nginx:1.25"
	expect: output: spec: replicas: 1
}
EOF

step "Run them"
run_tests 0 "2 passed, 0 failed" .

step "A wrong expectation fails, naming the case and the field"
sed 's/expect: output: spec: replicas: 1/expect: output: spec: replicas: 2/' web_test.cue > web_test.cue.new
mv web_test.cue.new web_test.cue
run_tests 1 "1 passed, 1 failed" .

echo
echo "PASS: Test what a component renders"
