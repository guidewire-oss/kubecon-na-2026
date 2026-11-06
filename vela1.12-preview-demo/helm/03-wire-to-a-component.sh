#!/usr/bin/env bash
# KubeVela 1.12 demo: Wire a chart to a component beside it
# podinfo gets its Redis address from a Redis component in the same Application: a component read fills a values ConfigMap, and the chart takes it through valuesFrom.
#
# Needs: featureGates.enableCelExpressions=true, the vela CLI 1.12, and the helm CLI to look at the release.
# Runs against the cluster in your current kubeconfig.
#
#   ./03-wire-to-a-component.sh            run the demo and check the result
#   ./03-wire-to-a-component.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-helm-3

cleanup() {
  kubectl delete app podinfo-cached -n "$NS" --ignore-not-found   # uninstalls the Helm release
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
# wait_for <description> <expected> <timeout seconds> <command...>: poll until the command prints the value
wait_for() {
  local d=$1 want=$2 t=$3 got=""; shift 3
  for _ in $(seq 1 $((t / 5))); do
    got=$("$@" 2>/dev/null || true)
    [ "$got" = "$want" ] && { echo "ok: $d = $got"; return 0; }
    sleep 5
  done
  fail "$d: expected '$want', got '$got' after ${t}s"
}

kubectl wait --for=delete namespace/"$NS" --timeout=120s >/dev/null 2>&1 || true
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "Apply the Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: podinfo-cached
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  components:
    - name: cache
      type: webservice
      properties:
        image: redis:7
        ports:
          - port: 6379
            expose: true
    - name: values                  # waits for cache to be healthy, then reads its Service
      type: k8s-objects
      properties:
        objects:
          - apiVersion: v1
            kind: ConfigMap
            metadata:
              name: podinfo-values
            data:
              values.yaml: 'cache: tcp://$(component.cache.outputs.webserviceExpose.metadata.name):6379'
    - name: podinfo
      type: helmchart
      dependsOn: [values]
      properties:
        chart:
          source: podinfo
          repoURL: https://stefanprodan.github.io/podinfo
          version: "6.7.1"
        valuesFrom:
          - kind: ConfigMap
            name: podinfo-values
        healthStatus:
          - resource:
              kind: Deployment
            condition:
              type: Available
EOF

step "Wait for it to run"
wait_app podinfo-cached "$NS"
vela status podinfo-cached -n "$NS"

step "Check the result"
expect "read edge" "cache" \
  "$(kubectl get app podinfo-cached -n "$NS" -o json | jq -r '.status.dependencies[]? | select(.component=="values" and .source=="expression") | .dependsOn')"
expect "values ConfigMap" "cache: tcp://cache:6379" \
  "$(kubectl get configmap podinfo-values -n "$NS" -o jsonpath='{.data.values\.yaml}')"
expect "Helm release status" "deployed" \
  "$(helm list -n "$NS" -o json | jq -r '.[] | select(.name=="podinfo") | .status')"
args=$(kubectl get deploy podinfo -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].command}')
case "$args" in *--cache-server=tcp://cache:6379*) echo "ok: podinfo runs with --cache-server=tcp://cache:6379" ;; *) fail "podinfo command: $args" ;; esac
wait_for "podinfo Available" "True" 120 \
  kubectl get deploy podinfo -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'

echo
echo "PASS: Wire a chart to a component beside it"
