#!/usr/bin/env bash
# KubeVela 1.12 demo: Park a known defect, and know when it is fixed
# A health case that pins a real defect is parked with @pending; once web.cue is fixed, --check-pending insists the marker comes off.
#
# Needs: the vela CLI 1.12. No cluster: vela def test runs locally.
#
#   ./03-pending-defect.sh            run the demo and check the result
#   ./03-pending-defect.sh --cleanup  nothing to remove; files live in a temp directory
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

step "Write the component and its status tests"
cat > web.cue <<'EOF'
web: {
	type: "component"
	attributes: {
		workload: definition: {
			apiVersion: "apps/v1"
			kind:       "Deployment"
		}
		status: {
			healthPolicy: #"""
				isHealth: context.output.status.readyReplicas == context.output.spec.replicas
				"""#
			customStatus: #"""
				message: "Ready:\(context.output.status.readyReplicas)/\(context.output.spec.replicas)"
				"""#
			details: #"""
				image: parameter.image
				"""#
		}
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
	if parameter.expose {
		outputs: service: {
			apiVersion: "v1"
			kind:       "Service"
			metadata: name: context.name
		}
	}
	parameter: {
		image:    string
		replicas: *1 | int
		expose:   *false | bool
	}
}
EOF
cat > web_status_test.cue <<'EOF'
import "vela/test"

@label(health)

_web: {
	definition: "web"
	context: name: "shop"
	parameter: {image: "nginx:1.25", replicas: 2}
}

"healthy once every replica is ready": test.#ComponentStatus & _web & {
	observed: output: status: readyReplicas: 2
	expect: {
		healthy: true
		message: "Ready:2/2"
		details: image: "nginx:1.25"
	}
}

"not healthy while a replica is starting": test.#ComponentStatus & _web & {
	observed: output: status: readyReplicas: 1
	expect: {healthy: false, message: "Ready:1/2"}
}

"not healthy before the Deployment reports a status": test.#ComponentStatus & _web & {
	expect: {healthy: false, message: "Ready:0/2"}
} @pending(the policy reads readyReplicas before the Deployment has one)
EOF

step "The defect is parked: the run passes and reports it as pending"
run_tests 0 "2 passed, 0 failed, 1 pending" . -v
run_tests 0 "2 passed, 0 failed, 1 pending" . --check-pending

step "Without the marker, the case shows the defect"
sed 's/^} @pending(.*)$/}/' web_status_test.cue > unparked_test.cue.txt
mkdir unparked && cp web.cue unparked/ && mv unparked_test.cue.txt unparked/web_status_test.cue
run_tests 1 "2 passed, 1 failed" unparked
rm -rf unparked

step "--fail-on-pending refuses any parked case"
run_tests 1 "2 passed, 0 failed, 1 pending" . --fail-on-pending

step "Fix the health policy and status message"
cat > web.cue <<'EOF'
web: {
	type: "component"
	attributes: {
		workload: definition: {
			apiVersion: "apps/v1"
			kind:       "Deployment"
		}
		status: {
			healthPolicy: #"""
				_ready: *0 | int
				if context.output.status.readyReplicas != _|_ {
					_ready: context.output.status.readyReplicas
				}
				isHealth: _ready == context.output.spec.replicas
				"""#
			customStatus: #"""
				_ready: *0 | int
				if context.output.status.readyReplicas != _|_ {
					_ready: context.output.status.readyReplicas
				}
				message: "Ready:\(_ready)/\(context.output.spec.replicas)"
				"""#
			details: #"""
				image: parameter.image
				"""#
		}
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
	if parameter.expose {
		outputs: service: {
			apiVersion: "v1"
			kind:       "Service"
			metadata: name: context.name
		}
	}
	parameter: {
		image:    string
		replicas: *1 | int
		expose:   *false | bool
	}
}
EOF
run_tests 1 "2 passed, 0 failed, 1 no longer pending" . --check-pending

step "Remove the marker: the case now guards the fix"
sed 's/^} @pending(.*)$/}/' web_status_test.cue > web_status_test.cue.new
mv web_status_test.cue.new web_status_test.cue
run_tests 0 "3 passed, 0 failed" . --check-pending

echo
echo "PASS: Park a known defect, and know when it is fixed"
