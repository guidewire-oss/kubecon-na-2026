#!/usr/bin/env bash
# KubeVela 1.12 demo: Test the custom source before anyone binds it
# test.#SourceExec resolves the acme-platform source against a throwaway API server, with the resources the test gives it.
#
# Needs: the vela CLI 1.12 and envtest's etcd and kube-apiserver (setup-envtest use -p path).
# Touches no cluster: the files go to a temporary directory and the API server is local.
#
#   ./04-test-custom-source.sh            run the demo and check the result
#   ./04-test-custom-source.sh --cleanup  nothing to remove; accepted for symmetry
set -euo pipefail

if [ "${1:-}" = "--cleanup" ]; then exit 0; fi

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if [ -z "${KUBEBUILDER_ASSETS:-}" ]; then
  KUBEBUILDER_ASSETS="$HOME/Library/Application Support/io.kubebuilder.envtest/k8s/1.31.0-darwin-arm64"
  if [ ! -x "$KUBEBUILDER_ASSETS/kube-apiserver" ] && command -v setup-envtest >/dev/null 2>&1; then
    KUBEBUILDER_ASSETS="$(setup-envtest use -p path)"
  fi
  export KUBEBUILDER_ASSETS
fi
[ -x "$KUBEBUILDER_ASSETS/kube-apiserver" ] ||
  fail "no kube-apiserver in '$KUBEBUILDER_ASSETS'; install one with: go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest && setup-envtest use"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

step "The definition from the previous demo, acme-platform.cue"
cat > acme-platform.cue <<'EOF'
import (
	"vela/kube"
	"strconv"
)

"acme-platform": {
	type:        "source"
	description: "The registry, replica count and tier this cluster runs with"
	attributes: {}
}

template: {
	schema: {
		registry: string
		replicas: int
		tier:     "gold" | "silver" | "bronze"
	}

	storage: {
		storageTTL:     "1m"
		onStaleFailure: "use-stale"
	}

	// Parameterless: where the settings live is the platform's business.
	parameter: {}

	_cm: kube.#Get & {
		$params: {
			cluster: context.cluster
			resource: {
				apiVersion: "v1"
				kind:       "ConfigMap"
				metadata: {
					name:      "acme-platform"
					namespace: "acme-system"
				}
			}
		}
	}
	_data: _cm.$returns.data

	output: {
		registry: _data.registry
		replicas: strconv.Atoi(_data.replicas)   // convert once, here
		tier:     _data.tier
	}
}
EOF

step "Put acme-platform_test.cue beside it"
cat > acme-platform_test.cue <<'EOF'
import (
	"vela/test"
	"vela/kube"
)

acmeNamespace: kube.#Apply & {$params: value: {
	apiVersion: "v1"
	kind:       "Namespace"
	metadata: name: "acme-system"
}} @before()

_settings: {
	apiVersion: "v1"
	kind:       "ConfigMap"
	metadata: {name: "acme-platform", namespace: "acme-system"}
	data: {registry: "docker.io/library", replicas: "3", tier: "gold"}
}

"publishes typed settings": test.#SourceExec & {
	definition: "acme-platform"
	resources: [_settings]
	expect: output: {registry: "docker.io/library", replicas: 3, tier: "gold"}
}

"caches for a minute, serving stale on failure": test.#SourceExec & {
	definition: "acme-platform"
	resources: [_settings]
	expect: storage: {ttl: "1m", onStaleFailure: "use-stale"}
}
EOF

step "Run it"
out=$(vela def test . -v 2>&1) || { echo "$out"; fail "vela def test failed"; }
echo "$out"
echo "$out" | grep -q '^2 passed, 0 failed' || fail "expected 2 passed, 0 failed"
echo "ok: 2 passed, 0 failed"

echo
echo "PASS: Test the custom source before anyone binds it"
