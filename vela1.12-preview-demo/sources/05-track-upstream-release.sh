#!/usr/bin/env bash
# KubeVela 1.12 demo: Track an upstream release with http-get
# http-get reads the GitHub releases API, so podinfo's image tag and its UI message follow its latest release.
#
# Needs: featureGates.enableCelExpressions=true, the vela CLI 1.12, and internet egress from the controller.
# Runs against the cluster in your current kubeconfig.
#
#   ./05-track-upstream-release.sh            run the demo and check the result
#   ./05-track-upstream-release.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-sources-5

cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
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

kubectl wait --for=delete namespace/"$NS" --timeout=120s >/dev/null 2>&1 || true
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Apply the Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: podinfo-latest
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  sources:
    - name: release
      type: http-get
      properties:
        url: https://api.github.com/repos/stefanprodan/podinfo/releases/latest
      autoUpdate: true          # a new podinfo release rolls out on its own
  components:
    - name: podinfo
      type: webservice
      properties:
        # the body is parsed JSON of no declared type, so say what you want from it
        image: 'ghcr.io/stefanprodan/podinfo:$(string(source.release.content.tag_name))'
        ports:
          - port: 9898
            expose: true
        env:
          - name: PODINFO_UI_MESSAGE
            value: 'podinfo $(string(source.release.content.tag_name)), released $(string(source.release.content.published_at))'
EOF

step "Wait for it to run"
wait_app podinfo-latest "$NS"
vela status podinfo-latest -n "$NS" --sources

step "Check the result"
expect "source phase" "Resolved" \
  "$(kubectl get app podinfo-latest -n "$NS" -o jsonpath='{.status.sources[0].phase}')"
image=$(kubectl get deploy podinfo -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
tag=${image##*:}
echo "latest podinfo release: $tag"
case "$tag" in [0-9]*.[0-9]*.[0-9]*) echo "ok: image tag looks like a release" ;; *) fail "image: got '$image'" ;; esac
msg=$(kubectl get deploy podinfo -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PODINFO_UI_MESSAGE")].value}')
case "$msg" in "podinfo $tag, released "*) echo "ok: UI message = $msg" ;; *) fail "UI message: got '$msg'" ;; esac
echo "see it: kubectl port-forward -n $NS svc/podinfo 9898:9898, then open http://localhost:9898"

echo
echo "PASS: Track an upstream release with http-get"
