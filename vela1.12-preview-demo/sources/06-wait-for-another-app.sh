#!/usr/bin/env bash
# KubeVela 1.12 demo: Hold a frontend until its database is healthy
# vela-app reads another Application's health, so the frontend runs no replicas until shop-db is healthy and scales up on its own once it is.
#
# Needs: featureGates.enableCelExpressions=true and featureGates.enableSourceAutoUpdate=true, and the vela CLI 1.12.
# Runs against the cluster in your current kubeconfig.
#
#   ./06-wait-for-another-app.sh            run the demo and check the result (up to about 6 minutes: it waits for a resync)
#   ./06-wait-for-another-app.sh --cleanup  remove everything it created
set -euo pipefail

NS=demo-sources-6

cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  kubectl delete secret -n vela-system -l sourcedefinition.oam.dev/namespace="$NS" --ignore-not-found
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
replicas() { kubectl get deploy web -n "$NS" -o jsonpath='{.spec.replicas}'; }

kubectl wait --for=delete namespace/"$NS" --timeout=120s >/dev/null 2>&1 || true
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "The database, its own Application"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: shop-db
spec:
  components:
    - name: redis
      type: webservice
      properties:
        image: redis:7
        ports:
          - port: 6379
            expose: true
EOF

step "The frontend, applied straight away, while shop-db is still starting"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: shop-web
  annotations:
    app.oam.dev/cel-expressions: "true"
spec:
  sources:
    - name: db
      type: vela-app
      properties:
        name: shop-db            # must already exist: a missing Application fails the source
      autoUpdate: true
  components:
    - name: web
      type: webservice
      properties:
        image: nginx:1.27
        env:
          - name: DB_PHASE
            value: '$(source.db.phase)'
      traits:
        - type: scaler
          properties:
            replicas: '$(source.db.healthy ? 2 : 0)'
EOF

wait_app shop-web "$NS"
first=$(replicas)
echo "web replicas while shop-db started: $first"
vela status shop-web -n "$NS" --sources

step "Wait for shop-db, then for web to follow"
wait_app shop-db "$NS"
echo "note: vela-app caches for 1 minute, and is re-read at the next reconcile after that (the resync runs every 5 minutes)"
wait_for "web replicas" "2" 420 replicas
expect "DB_PHASE" "running" \
  "$(kubectl get deploy web -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DB_PHASE")].value}')"
vela status shop-web -n "$NS" --sources

echo "note: after the re-dispatch, health in status catches up at the next resync"
wait_app shop-web "$NS" 420

echo
echo "PASS: Hold a frontend until its database is healthy"
