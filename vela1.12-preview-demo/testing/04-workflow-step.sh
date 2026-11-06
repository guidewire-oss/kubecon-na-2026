#!/usr/bin/env bash
# KubeVela 1.12 demo: Test a workflow step against a local API server
# notify reads a ConfigMap and posts it to a webhook; the cases seed the ConfigMap, mock the HTTP call, and check the calls, the phase and what is left behind.
#
# Needs: the vela CLI 1.12, and etcd plus kube-apiserver from setup-envtest
# (KUBEBUILDER_ASSETS). No cluster: vela def test starts and stops a local API server.
#
#   ./04-workflow-step.sh            run the demo and check the result
#   ./04-workflow-step.sh --cleanup  nothing to remove; files live in a temp directory
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

# Workflow step cases run against a local API server; point at its binaries.
if [ -z "${KUBEBUILDER_ASSETS:-}" ]; then
  KUBEBUILDER_ASSETS="$HOME/Library/Application Support/io.kubebuilder.envtest/k8s/1.31.0-darwin-arm64"
fi
export KUBEBUILDER_ASSETS
[ -x "$KUBEBUILDER_ASSETS/kube-apiserver" ] || \
  fail "no kube-apiserver in $KUBEBUILDER_ASSETS; run: export KUBEBUILDER_ASSETS=\"\$(setup-envtest use -p path)\""

step "Write the step and its tests"
cat > notify.cue <<'EOF'
import (
	"vela/kube"
	"vela/http"
)

notify: {
	type:        "workflow-step"
	description: "Posts a ConfigMap's message to a webhook"
}
template: {
	settings: kube.#Read & {
		$params: value: {
			apiVersion: "v1"
			kind:       "ConfigMap"
			metadata: {name: parameter.config, namespace: context.namespace}
		}
	}
	post: http.#HTTPDo & {
		$params: {
			method: "POST"
			url:    parameter.webhook
			request: body: settings.$returns.value.data.message
		}
	}
	parameter: {
		config:  string
		webhook: string
	}
}
EOF
cat > notify_test.cue <<'EOF'
import (
	"vela/kube"
	"vela/test"
)

_settings: {
	apiVersion: "v1"
	kind:       "ConfigMap"
	metadata: name: "settings"
	data: message: "deployed"
}

_notify: {
	definition: "notify"
	parameter: {config: "settings", webhook: "https://hooks.example.com/deploy"}
}

"posts the ConfigMap's message": test.#WorkflowStepExec & _notify & {
	resources: [_settings]
	mocks: "vela/http": "#HTTPDo": $returns: {statusCode: 202, body: "ok"}
	expect: {
		phase: "succeeded"
		calls: {
			"vela/kube": "#Read": [{$returns: value: data: message: "deployed"}]
			"vela/http": "#HTTPDo": [{$params: {method: "POST", request: body: "deployed"}}]
		}
	}
}

"an unmocked post fails the step": test.#WorkflowStepExec & _notify & {
	resources: [_settings]
	expect: {
		phase:   "failed"
		message: =~"reaches outside the cluster"
	}
}

"leaves the ConfigMap as it found it": test.#WorkflowStepExec & _notify & {
	resources: [_settings]
	mocks: "vela/http": "#HTTPDo": $returns: {statusCode: 202, body: "ok"}
	expect: checks: settings: {
		call: kube.#Read & {$params: value: {apiVersion: "v1", kind: "ConfigMap", metadata: name: "settings"}}
		returns: value: data: message: "deployed"
	}
}
EOF

step "Run them against a local API server"
run_tests 0 "3 passed, 0 failed" . -v

step "Only the workflow step cases, as CI would select them"
run_tests 0 "3 passed, 0 failed" . --label-filter workflow-step

echo
echo "PASS: Test a workflow step against a local API server"
