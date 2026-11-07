#!/usr/bin/env bash
# Bootstrap, check and reset the Vela MCP demo on the one cluster every demo in this repo
# uses: the k3d cluster kubecon, created by kubevela-bucket-floci-demo/demo.sh
# (a copy of demo-init.sh, adapted). Run on the host, where Docker, k3d, kubectl, helm,
# go and git are.
#
# Differences from demo-init.sh:
#   - it never creates or deletes a cluster: it reuses the k3d cluster CLUSTER (kubecon).
#     Create it first with: kubevela-bucket-floci-demo/demo.sh --cluster-only
#   - it uses the vela CLI in ~/workspace/kubevela/bin and never clones or builds kubevela
#   - vela-core is expected at 1.12.0-alpha.1, as demo.sh installs it, and is left alone
#     by default; run adds CloudNativePG and its own Floci to the cluster
#   - reset removes only what this demo adds: it no longer deletes every *.services.k8s.aws
#     CRD, so the bucket demo's ACK S3 CRDs survive
#
#   ./demo-init-kubecon.sh [run] [--upgrade] [--yes]
#                          the whole demo, guided: works in ./kubevela-demo (created
#                          unless the current folder is already one), clones the skills
#                          there, adds CloudNativePG and Floci to the cluster, removes
#                          leftovers of an earlier run, waits up to 5 minutes for every
#                          pod, prints the MCP client setup, then walks acts 1 to 3 one
#                          Enter at a time
#   ./demo-init-kubecon.sh up [--upgrade|--keep] [--yes]
#                          verify vela-core, install or verify CloudNativePG, seed act 1,
#                          preload images, warm the Go module cache
#   ./demo-init-kubecon.sh ack [--floci] [--upgrade|--keep] [--yes]
#                          install or verify the ACK DynamoDB controller (act 4, live).
#                          --floci first deploys the Floci AWS emulator in the cluster
#                          and points ACK at it, so tables are really created, locally
#   ./demo-init-kubecon.sh diag    why pods were evicted, node pressure, Docker VM CPUs, memory, disk
#   ./demo-init-kubecon.sh check   pre-talk checklist with the versions found; non-zero if off
#   ./demo-init-kubecon.sh reset   undo everything this demo adds, keep the cluster
#
# Which cluster: CONTEXT if set (must be reachable, and your KUBECONFIG is used as it is);
# else the k3d cluster CLUSTER, which must already exist (started if stopped). demo.sh
# put its context, k3d-kubecon, in your kubeconfig; if it is missing, the kubeconfig is
# written by k3d and exported as KUBECONFIG. This script never creates or deletes a cluster.
#
# Components already installed at another version, or by another installer, stop the
# script. --upgrade moves them to the pinned versions (CRDs first); --keep leaves them.
#
# Settings (environment variables):
#   CONTEXT            kube context to use                   (see above)
#   CLUSTER            k3d cluster to use                    (kubecon)
#   VELA               vela binary with the mcp command      (~/workspace/kubevela/bin/vela)
#   VELA_CORE_VERSION  vela-core chart version expected      (1.12.0-alpha.1)
#   CNPG_VERSION       CloudNativePG operator version        (1.30.1)
#   ACK_DDB_VERSION    ACK DynamoDB chart version            (1.14.1)
#   AWS_REGION         region the ACK controller uses        (us-west-2)
#   AWS_CREDENTIALS_FILE  shared credentials file for ACK, read into a Secret (optional)
#   AWS_ENDPOINT_URL   in-cluster URL of an AWS emulator for ACK (optional)
#   CNPG_PG_IMAGE      PostgreSQL image to preload            (CNPG 1.30.1's default)
#   FLOCI_VERSION      Floci AWS emulator image tag for --floci (nightly-11052026)
#   CA_BUNDLE          PEM file with the root CA of a TLS-inspecting proxy or VPN. Needed
#                      when the network re-signs HTTPS: the nodes' container runtime does
#                      not trust it and cannot pull images. Copied into every k3d node.
#   LIVE_DIR           where the agent works on stage        (~/kubecon-live; run: kubevela-demo/live)
#   SKILLS_REPO       skills repository run clones          (https://github.com/kubevela/skills.git)
#   WAIT_TIMEOUT       seconds run waits for pods            (300)
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
LIVE_DIR_GIVEN=${LIVE_DIR:-}
CLUSTER=${CLUSTER:-kubecon}
VELA=${VELA:-$HOME/workspace/kubevela/bin/vela}
VELA_GIVEN=$VELA   # always "given": this copy never builds vela
SKILLS_REPO=${SKILLS_REPO:-https://github.com/kubevela/skills.git}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-300}
SKILLS=(kubevela-developer kubevela-sre kubevela-platform-engineer kubevela-defkit-author)
VELA_CORE_VERSION=${VELA_CORE_VERSION:-1.12.0-alpha.1}
CNPG_VERSION=${CNPG_VERSION:-1.30.1}
ACK_DDB_VERSION=${ACK_DDB_VERSION:-1.14.1}
AWS_REGION=${AWS_REGION:-us-west-2}
LIVE_DIR=${LIVE_DIR:-$HOME/kubecon-live}
# The other subcommands find what run made when started from, or next to, kubevela-demo.
for d in "$PWD" "$PWD/kubevela-demo"; do
  [[ "$(basename "$d")" == kubevela-demo && -d "$d" ]] || continue
  [[ -z "$LIVE_DIR_GIVEN" ]] && LIVE_DIR=$d/live || true
  [[ -z "$VELA_GIVEN" && -x "$d/kubevela/bin/vela" ]] && VELA=$d/kubevela/bin/vela || true
done
# CNPG 1.30.1 starts PostgreSQL pods from its compiled-in default image, with the
# operator image as an init container (pkg/versions/versions.go at v1.30.1).
CNPG_PG_IMAGE=${CNPG_PG_IMAGE:-ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie}
VELA_CHART_REPO=https://kubevela.io/charts
ACK_CHART=oci://public.ecr.aws/aws-controllers-k8s/dynamodb-chart
# A dated nightly, not 2.4.0: the ACK DynamoDB controller calls DescribeContributorInsights
# on every read, and Floci implements it from 2026-11-02 (floci-io/floci#7326), after 2.4.0.
FLOCI_VERSION=${FLOCI_VERSION:-nightly-11052026}
FLOCI_IMAGE="floci/floci:$FLOCI_VERSION"
FLOCI_URL=http://emulator.floci.svc.cluster.local:4566
# Floci takes any non-empty credentials; a 12-digit access key ID becomes the account ID.
FLOCI_ACCOUNT=000000000000

case "$(uname -m)" in
  arm64 | aarch64) PETCLINIC_IMAGE=springcommunity/spring-petclinic:3.5.0 ;;  # arm64 build
  *) PETCLINIC_IMAGE=springcommunity/spring-petclinic:3.5.6 ;;              # amd64 build
esac
PRELOAD_IMAGES=("$PETCLINIC_IMAGE" nginx:1.27 busybox:1.36 "$CNPG_PG_IMAGE" "ghcr.io/cloudnative-pg/cloudnative-pg:$CNPG_VERSION" "$FLOCI_IMAGE")

MODE=strict   # strict | upgrade | keep
MODE_GIVEN=0
ASSUME_YES=0
USE_FLOCI=0
CTX=""
FAILED=0

k() { kubectl --context "$CTX" "$@"; }
h() { helm --kube-context "$CTX" "$@"; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILED=1; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
reachable() { kubectl --context "$1" get --raw /readyz --request-timeout=5s >/dev/null 2>&1; }
# has matches like grep -q but reads all its input: grep -q exits on the first match,
# which kills the writer with SIGPIPE, and pipefail then fails a pipeline that matched.
has() { grep "$@" >/dev/null; }
k3d_exists() { k3d cluster list -o json 2>/dev/null | has "\"name\": *\"$CLUSTER\""; }
strip_v() { echo "${1#v}"; }

parse_flags() {
  for a in "$@"; do
    case "$a" in
      --upgrade) MODE=upgrade; MODE_GIVEN=1 ;;
      --keep) MODE=keep; MODE_GIVEN=1 ;;
      --yes | -y) ASSUME_YES=1 ;;
      --floci) USE_FLOCI=1 ;;
      *) die "unknown flag: $a" ;;
    esac
  done
}

# ---------------------------------------------------------------- cluster selection

# select_cluster sets CTX and points KUBECONFIG at the cluster. This copy never creates
# a cluster: 00-setup.sh made the k3d cluster and left ~/.kube/config alone, so the
# kubeconfig comes from k3d and is exported for kubectl, helm, vela and the MCP server.
select_cluster() {
  if [[ -n "${CONTEXT:-}" ]]; then
    reachable "$CONTEXT" || die "CONTEXT=$CONTEXT is not reachable"
    CTX=$CONTEXT
    say "Using context $CTX (from CONTEXT)"
    return 0
  fi
  need k3d
  k3d_exists || die "no k3d cluster named $CLUSTER: run kubevela-bucket-floci-demo/demo.sh --cluster-only first, or set CLUSTER or CONTEXT"
  CTX="k3d-$CLUSTER"
  # demo.sh leaves the context in the default kubeconfig; fall back to a k3d-written one.
  if ! kubectl config get-contexts -o name 2>/dev/null | has -x "$CTX"; then
    KUBECONFIG=$(k3d kubeconfig write "$CLUSTER")
    export KUBECONFIG
  fi
  if ! reachable "$CTX"; then
    say "Starting stopped k3d cluster $CLUSTER"
    k3d cluster start "$CLUSTER" >/dev/null
    reachable "$CTX" || die "k3d cluster $CLUSTER started but $CTX is not reachable"
  fi
  say "Using the k3d cluster $CLUSTER ($CTX), kubeconfig ${KUBECONFIG:-$HOME/.kube/config}"
}

choose_context() {
  select_cluster
  confirm_context
  kubectl config use-context "$CTX" >/dev/null   # vela and the MCP use the current context
  ensure_registry_trust
}

# mcp_env_args prints the --env argument that points an MCP client at this cluster's
# kubeconfig; empty when KUBECONFIG is not set (CONTEXT with your own kubeconfig).
mcp_env_args() {
  [[ -n "${KUBECONFIG:-}" ]] && printf -- '--env KUBECONFIG=%s' "$KUBECONFIG" || true
}

confirm_context() {
  local server nodes
  server=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CTX\")].context.cluster}")\")].cluster.server}")
  nodes=$(k get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "  context $CTX, API server $server, $nodes nodes"
  (( ASSUME_YES )) && return 0
  read -r -p "  Install the demo components into this cluster? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "Stopped; nothing was changed."
}

is_k3d_ctx() { [[ "$CTX" == k3d-* ]]; }

# tls_intercepted succeeds when HTTPS to Docker Hub is re-signed by something a
# container's public CA store does not trust, as a TLS-inspecting proxy or VPN does.
tls_intercepted() {
  local out
  out=$(docker run --rm curlimages/curl:8.10.1 -sS -o /dev/null -w '%{http_code}' https://registry-1.docker.io/v2/ 2>&1 || true)
  [[ "$out" == *401* ]] && return 1
  [[ "$out" == *certificate* || "$out" == *SSL* ]]
}

# ensure_registry_trust makes the nodes trust CA_BUNDLE when the network needs it.
# The file goes into /etc/ssl/certs, which k3s reads at start, so changed nodes are
# restarted. Nodes that already have the same file are left alone.
ensure_registry_trust() {
  say "Checking image pulls through this network"
  if ! tls_intercepted; then
    ok "HTTPS to Docker Hub is not re-signed; nodes pull with their own CA store"
    return 0
  fi
  # demo.sh --zscaler mounts the proxy CA into the nodes when it creates the cluster.
  local first
  first=$(k3d node list --no-headers 2>/dev/null | awk -v c="${CTX#k3d-}" '$3==c && $2!="loadbalancer" {print $1; exit}')
  if is_k3d_ctx && [[ -n "$first" ]] && docker exec "$first" test -f /etc/ssl/certs/registry-ca.crt 2>/dev/null; then
    ok "nodes already trust the CA that demo.sh mounted (registry-ca.crt)"
    return 0
  fi
  [[ -n "${CA_BUNDLE:-}" ]] || die "HTTPS on this network is re-signed by a proxy or VPN, so the cluster's nodes cannot pull images
(x509: certificate signed by unknown authority). Export its root certificate to a PEM file and set CA_BUNDLE.
On macOS, all trusted roots in one file:
  security find-certificate -a -p /Library/Keychains/System.keychain /System/Library/Keychains/SystemRootCertificates.keychain > ~/proxy-ca.pem
then: CA_BUNDLE=~/proxy-ca.pem ./demo-init-kubecon.sh up"
  [[ -f "$CA_BUNDLE" ]] || die "CA_BUNDLE=$CA_BUNDLE is not a file"
  grep -q 'BEGIN CERTIFICATE' "$CA_BUNDLE" || die "CA_BUNDLE=$CA_BUNDLE holds no PEM certificate"
  if ! is_k3d_ctx; then
    warn "$CTX is not k3d: make its nodes trust $CA_BUNDLE yourself, or image pulls fail with x509 errors"
    return 0
  fi
  local name=${CTX#k3d-} changed=0 n tmp
  tmp=$(mktemp)
  for n in $(k3d node list --no-headers 2>/dev/null | awk -v c="$name" '$3==c && $2!="loadbalancer" {print $1}'); do
    if docker cp "$n:/etc/ssl/certs/demo-proxy-ca.pem" "$tmp" >/dev/null 2>&1 && cmp -s "$tmp" "$CA_BUNDLE"; then
      continue
    fi
    docker cp "$CA_BUNDLE" "$n:/etc/ssl/certs/demo-proxy-ca.pem" >/dev/null
    changed=1
  done
  rm -f "$tmp"
  if (( ! changed )); then ok "nodes already trust $CA_BUNDLE"; return 0; fi
  echo "  restarting $name so its nodes load the CA"
  k3d cluster stop "$name" >/dev/null && k3d cluster start "$name" >/dev/null
  local _
  for _ in $(seq 60); do reachable "$CTX" && break; sleep 2; done
  k wait --for=condition=Ready node --all --timeout=120s >/dev/null || die "nodes did not become Ready after the restart"
  # Pods that gave up on their sandbox are retried by the kubelet; failed jobs are not.
  k -n kube-system delete pod --field-selector=status.phase=Failed >/dev/null 2>&1 || true
  ok "nodes trust $CA_BUNDLE"
}

# warn_events prints the newest warning events in a namespace, for a failed wait.
warn_events() {
  echo "  newest warning events in $1:" >&2
  k -n "$1" get events --field-selector type=Warning --sort-by=.lastTimestamp -o custom-columns=OBJECT:.involvedObject.name,REASON:.reason,MESSAGE:.message --no-headers 2>/dev/null |
    tail -5 | cut -c1-220 | sed 's/^/    /' >&2
  grep -q x509 <<<"$(k -n "$1" get events --field-selector type=Warning -o jsonpath='{.items[*].message}' 2>/dev/null)" &&
    echo "  x509 errors: the nodes do not trust your network's TLS proxy; set CA_BUNDLE and run up again" >&2
  return 0
}

# release_status prints a Helm release's status, or nothing when it does not exist.
release_status() {
  h status "$1" -n "$2" -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null || true
}

# clear_failed_release removes a release whose install never succeeded, which
# upgrade --install cannot recover from ("has no deployed releases").
clear_failed_release() {
  local st
  st=$(release_status "$1" "$2")
  case "$st" in
    failed | pending-install | pending-upgrade | pending-rollback)
      warn "release $1 in $2 is $st from an earlier run; removing it to install again"
      h uninstall "$1" -n "$2" --wait >/dev/null 2>&1 || h uninstall "$1" -n "$2" --no-hooks >/dev/null 2>&1 || true ;;
  esac
}

# ---------------------------------------------------------------- version detection
# Each prints "version how" or nothing when the component is absent.

found_vela_core() {
  local rel v img
  rel=$(h list -n vela-system -o json 2>/dev/null | python3 -c 'import json,sys
for r in json.load(sys.stdin):
    if r["chart"].startswith("vela-core-"): print(r["name"], r["chart"][len("vela-core-"):]); break' 2>/dev/null || true)
  if [[ -n "$rel" ]]; then echo "${rel#* } helm:${rel%% *}"; return; fi
  v=$(k -n vela-system get deploy -l controller.oam.dev/name=vela-core -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || true)
  img=$(k -n vela-system get deploy -l controller.oam.dev/name=vela-core -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)
  [[ -z "$v" && -n "$img" ]] && v=${img##*:}
  [[ -n "$v" ]] && echo "$(strip_v "$v") other"
  return 0
}

found_cnpg() {
  local img managed
  img=$(k -n cnpg-system get deploy cnpg-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  [[ -z "$img" ]] && return 0
  managed=$(k -n cnpg-system get deploy cnpg-controller-manager -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
  if [[ "$managed" == Helm ]]; then echo "$(strip_v "${img##*:}") helm"; else echo "$(strip_v "${img##*:}") manifest"; fi
}

found_ack() {
  local rel
  rel=$(h list -A -o json 2>/dev/null | python3 -c 'import json,sys
for r in json.load(sys.stdin):
    if r["chart"].startswith("dynamodb-chart-"): print(r["name"], r["namespace"], r["chart"][len("dynamodb-chart-"):]); break' 2>/dev/null || true)
  if [[ -n "$rel" ]]; then
    read -r name ns ver <<<"$rel"
    echo "$ver helm:$name@$ns"
  elif k get crd tables.dynamodb.services.k8s.aws >/dev/null 2>&1; then
    echo "unknown crds-only"
  fi
  return 0
}

# decide NAME FOUND WANT EXPECTED_HOW -> prints install | skip | upgrade | keep, or dies
decide() {
  local name=$1 found=$2 want=$3 expected=$4 ver how
  if [[ -z "$found" ]]; then echo install; return; fi
  ver=${found%% *}; how=${found#* }
  if [[ "$ver" == "$want" && "$how" == "$expected"* ]]; then echo skip; return; fi
  local older=""
  [[ "$ver" != unknown && "$(printf '%s\n%s\n' "$ver" "$want" | sort -V | head -1)" == "$ver" && "$ver" != "$want" ]] && older=" (older than the demo needs)"
  case "$MODE" in
    upgrade)
      [[ "$how" != "$expected"* ]] && die "$name $ver is installed by $how, not $expected; --upgrade cannot take it over.
Remove it yourself, or use --keep to run the demo on it."
      echo upgrade ;;
    keep) echo keep ;;
    *) die "$name $ver is installed ($how)$older; the demo pins $want ($expected).
Re-run with --upgrade to move it to $want (CRDs first), or --keep to leave it. Nothing was changed for $name." ;;
  esac
}

# ---------------------------------------------------------------- components

apply_chart_crds() {   # CHART_REF VERSION: helm never upgrades CRDs, so apply them first
  local d
  d=$(mktemp -d)
  helm pull "$1" --version "$2" --devel --untar --untardir "$d" >/dev/null
  if compgen -G "$d/*/crds/*.yaml" >/dev/null; then
    k apply --server-side --force-conflicts -f "$d"/*/crds/ >/dev/null
    ok "CRDs from $(basename "$1") $2 applied"
  fi
  rm -rf "$d"
}

ensure_vela_core() {
  say "vela-core (wants $VELA_CORE_VERSION)"
  local found action release=kubevela
  clear_failed_release kubevela vela-system
  found=$(found_vela_core)
  [[ -n "$found" ]] && echo "  found $found"
  action=$(decide vela-core "$found" "$VELA_CORE_VERSION" helm)
  [[ "$found" == *helm:* ]] && release=${found##*helm:}
  helm repo add kubevela "$VELA_CHART_REPO" --force-update >/dev/null
  case "$action" in
    skip) ok "vela-core $VELA_CORE_VERSION already installed" ;;
    keep) warn "keeping vela-core ${found%% *}" ;;
    install | upgrade)
      [[ "$action" == upgrade ]] && apply_chart_crds kubevela/vela-core "$VELA_CORE_VERSION"
      h upgrade --install "$release" kubevela/vela-core -n vela-system --create-namespace \
        --version "$VELA_CORE_VERSION" --devel --wait --timeout 10m >/dev/null ||
        { warn_events vela-system; die "vela-core $VELA_CORE_VERSION did not become ready"; }
      ok "vela-core $VELA_CORE_VERSION ${action}ed" ;;
  esac
  wait_vela_webhook
}

# wait_vela_webhook waits until the vela-core webhook Service has a ready endpoint.
# The chart install can return before it does, and every Application write goes
# through it.
wait_vela_webhook() {
  local _ ready
  for _ in $(seq 90); do
    ready=$(k -n vela-system get endpointslices -l kubernetes.io/service-name=vela-core-webhook \
      -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[*]}' 2>/dev/null || true)
    if [[ -n "$ready" ]]; then ok "vela-core webhook has a ready endpoint"; return 0; fi
    sleep 2
  done
  warn_events vela-system
  die "the vela-core webhook has no ready endpoint after 3 minutes; Applications cannot be written"
}

# vela_up applies the Application on stdin, retrying for up to 2 minutes while the
# webhook is still coming up; any other error fails at once.
vela_up() {
  local doc out _
  doc=$(cat)
  for _ in $(seq 24); do
    if out=$("$VELA" up -f - <<<"$doc" 2>&1); then return 0; fi
    [[ "$out" == *webhook* ]] || { printf '%s\n' "$out" >&2; return 1; }
    sleep 5
  done
  printf '%s\n' "$out" >&2
  return 1
}

ensure_cnpg() {
  say "CloudNativePG (wants $CNPG_VERSION)"
  local found action
  found=$(found_cnpg)
  [[ -n "$found" ]] && echo "  found $found"
  action=$(decide CloudNativePG "$found" "$CNPG_VERSION" manifest)
  case "$action" in
    skip) ok "CloudNativePG $CNPG_VERSION already installed" ;;
    keep) warn "keeping CloudNativePG ${found%% *}" ;;
    install | upgrade)
      # The release manifest carries the CRDs, so one server-side apply moves both.
      k apply --server-side --force-conflicts -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/releases/cnpg-${CNPG_VERSION}.yaml" >/dev/null
      k -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout 5m >/dev/null ||
        { warn_events cnpg-system; die "CloudNativePG $CNPG_VERSION did not become ready"; }
      ok "CloudNativePG $CNPG_VERSION ${action}ed" ;;
  esac
}

preload_images() {
  say "Preloading images"
  if ! is_k3d_ctx; then
    warn "$CTX is not a k3d cluster; images are not preloaded, so the nodes pull them on first use"
    return 0
  fi
  local name=${CTX#k3d-} img n missing
  local nodes
  nodes=$(k3d node list --no-headers 2>/dev/null | awk -v c="$name" '$3==c && $2!="loadbalancer" {print $1}')
  for img in "${PRELOAD_IMAGES[@]}"; do
    # Import only when a node lacks the image: each import copies it into every node,
    # and the pull, the tarball and the copies together are what fill a VM disk.
    missing=0
    for n in $nodes; do
      docker exec "$n" crictl inspecti "$(canonical_image "$img")" >/dev/null 2>&1 || { missing=1; break; }
    done
    if (( ! missing )); then ok "$img (already on the nodes)"; continue; fi
    docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null
    k3d image import -c "$name" "$img" >/dev/null
    ok "$img"
  done
}

# canonical_image spells a reference the way containerd stores it (docker.io/library/...).
canonical_image() {
  local ref=$1 first=${1%%/*}
  if [[ "$ref" != */* ]]; then ref=docker.io/library/$ref
  elif [[ "$first" != *.* && "$first" != *:* && "$first" != localhost ]]; then ref=docker.io/$ref
  fi
  echo "$ref"
}

seed_act1() {
  say "Seeding act 1 in team-a"
  for ns in team-a petclinic orders; do k create ns "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null; done
  vela_up <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: shop
  namespace: team-a
spec:
  components:
    - name: shop
      type: webservice
      properties:
        image: nginx:1.27
        ports:
          - port: 80
            expose: true
      traits:
        - type: scaler
          properties:
            replicas: 2
EOF
  vela_up <<'EOF'
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: broken
  namespace: team-a
spec:
  components:
    - name: broken
      type: webservice
      properties:
        image: busybox:1.36
        cmd:
          - sh
          - -c
          - 'if [ -z "$DB_URL" ]; then echo "DB_URL not set"; exit 1; fi; sleep 3600'
EOF
  ok "shop and broken applied"
}

warm_go_cache() {
  say "Warming the Go module cache"
  local d
  d=$(mktemp -d)
  # A throwaway module, deleted afterwards, so nothing prepared is left behind.
  if (cd "$d" && "$VELA" def init-module warm --components x -g example.com/warm >/dev/null &&
    cd warm && GOWORK=off go mod tidy >/dev/null 2>&1 && GOWORK=off go test ./... >/dev/null 2>&1); then
    ok "module cache warm"
  else
    warn "could not warm the module cache; go mod tidy will download on stage"
  fi
  rm -rf "$d"
}

# check_vela_build looks for what the demo needs from vela: the defkit module
# commands with --components, and vela mcp with --as. Help is read whole, from stdout
# and stderr, and matched in bash; a miss reports what the command printed.
check_vela_build() {
  VELA_BUILD_PROBLEM=""
  local out rc
  out=$("$VELA" def init-module --help 2>&1) && rc=0 || rc=$?
  [[ "$out" == *--components* ]] ||
    VELA_BUILD_PROBLEM="vela def init-module has no --components flag (exit $rc; it printed: $(head -5 <<<"$out")). "
  out=$("$VELA" mcp --help 2>&1) && rc=0 || rc=$?
  [[ "$out" == *"--as "* || "$out" == *"--as="* ]] ||
    VELA_BUILD_PROBLEM+="vela mcp has no --as flag (exit $rc; it printed: $(head -5 <<<"$out"))."
  [[ -z "$VELA_BUILD_PROBLEM" ]]
}

preflight() {
  for t in docker k3d kubectl helm go python3; do need "$t"; done
  [[ -x "$VELA" ]] || die "no vela binary at $VELA: build kubevela master there, or set VELA"
  check_vela_build || die "$VELA is not the demo build: $VELA_BUILD_PROBLEM
Rebuild it from a kubevela master checkout:
  make -C ~/workspace/kubevela vela-cli    # writes bin/vela"
  # Node filesystems of a local cluster live on the Docker VM's disk. Below about
  # 15 GiB free, pulls and the CNPG volume push the kubelet into disk-pressure evictions.
  local free_kb
  free_kb=$(docker run --rm busybox:1.36 df -k / 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -n "$free_kb" ]] && (( free_kb < 15 * 1024 * 1024 )); then
    die "Docker VM disk has $((free_kb / 1024 / 1024)) GiB free; free at least 15 GiB first:
  docker system df; docker builder prune -a; docker image prune -a; k3d cluster list"
  fi
}

# Later subcommands target the context up chose: it is the current one.
current_ctx() {
  select_cluster
}

# ---------------------------------------------------------------- subcommands

cmd_up() {
  preflight
  choose_context
  ensure_vela_core
  ensure_cnpg
  preload_images
  seed_act1
  warm_go_cache
  mkdir -p "$LIVE_DIR"
  cat <<EOF

Ready on $CTX. Next:
  1. Register the server with your MCP client, for example:
       claude mcp add --scope user $(mcp_env_args) kubevela -- \$($VELA mcp config --format command --allow-write --direct-namespace petclinic)
  2. Install the kubevela/skills skills for your client.
  3. Start the agent in $LIVE_DIR.
  4. Run ./demo-init-kubecon.sh check right before the talk, and ./demo-init-kubecon.sh ack during act 4.
EOF
}

# ensure_floci runs the Floci AWS emulator as a KubeVela Application. The component
# is not named floci: a Service named floci makes Kubernetes inject FLOCI_PORT, which
# Floci reads as its own port setting and fails on. Its console
# is a Docker sidecar, which a cluster does not have, so it is turned off; the
# services ACK uses, such as DynamoDB and STS, run in the Floci process.
ensure_floci() {
  say "Floci AWS emulator $FLOCI_VERSION in namespace floci"
  k create ns floci --dry-run=client -o yaml | k apply -f - >/dev/null
  vela_up <<EOF
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: floci
  namespace: floci
spec:
  components:
    - name: emulator
      type: webservice
      properties:
        image: $FLOCI_IMAGE
        ports:
          - port: 4566
            expose: true
        env:
          - name: FLOCI_SERVICES_UI_ENABLED
            value: "false"
          # Set explicitly: any Service named floci in the namespace would inject
          # FLOCI_PORT=tcp://..., and explicit env takes precedence over it.
          - name: FLOCI_PORT
            value: "4566"
EOF
  k -n floci rollout status deploy/emulator --timeout 5m >/dev/null ||
    { warn_events floci; die "Floci did not become ready"; }
  ok "Floci ready at $FLOCI_URL (account $FLOCI_ACCOUNT)"
}

ensure_floci_ready() {
  say "Waiting for Floci AWS emulator"
  k -n floci rollout status deploy/emulator --timeout 5m >/dev/null ||
    { warn_events floci; die "Floci did not become ready"; }
  ok "Floci ready at $FLOCI_URL (account $FLOCI_ACCOUNT)"
}

cmd_ack() {
  current_ctx
  if (( USE_FLOCI )); then
    [[ -n "${AWS_ENDPOINT_URL:-}${AWS_CREDENTIALS_FILE:-}" ]] && die "--floci sets the endpoint and credentials itself; unset AWS_ENDPOINT_URL and AWS_CREDENTIALS_FILE"
    ensure_floci
    ensure_floci_ready
    AWS_ENDPOINT_URL=$FLOCI_URL
  fi
  say "ACK DynamoDB controller on $CTX (wants $ACK_DDB_VERSION)"
  local found action release=ack-dynamodb-controller ns=ack-system
  clear_failed_release ack-dynamodb-controller ack-system
  found=$(found_ack)
  [[ -n "$found" ]] && echo "  found $found"
  action=$(decide "ACK DynamoDB" "$found" "$ACK_DDB_VERSION" helm)
  if [[ "$found" == *helm:* ]]; then release=${found##*helm:}; ns=${release#*@}; release=${release%@*}; fi
  case "$action" in
    skip) ok "ACK DynamoDB $ACK_DDB_VERSION already installed"; return 0 ;;
    keep) warn "keeping ACK DynamoDB ${found%% *}"; return 0 ;;
  esac
  [[ "$action" == upgrade ]] && apply_chart_crds "$ACK_CHART" "$ACK_DDB_VERSION"
  local args=(--set "aws.region=$AWS_REGION")
  if [[ -n "${AWS_CREDENTIALS_FILE:-}" ]]; then
    k create ns "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
    k -n "$ns" create secret generic ack-aws-credentials --from-file=credentials="$AWS_CREDENTIALS_FILE" \
      --dry-run=client -o yaml | k apply -f - >/dev/null
    args+=(--set aws.credentials.secretName=ack-aws-credentials)
  elif (( USE_FLOCI )); then
    # Placeholder credentials Floci accepts; they are not secret and work nowhere else.
    k create ns "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
    printf '[default]\naws_access_key_id = %s\naws_secret_access_key = floci\n' "$FLOCI_ACCOUNT" |
      k -n "$ns" create secret generic ack-aws-credentials --from-file=credentials=/dev/stdin --dry-run=client -o yaml | k apply -f - >/dev/null
    args+=(--set aws.credentials.secretName=ack-aws-credentials)
  fi
  if [[ -n "${AWS_ENDPOINT_URL:-}" ]]; then
    args+=(--set "aws.endpoint_url=$AWS_ENDPOINT_URL" --set aws.allow_unsafe_aws_endpoint_urls=true)
  fi
  h upgrade --install "$release" "$ACK_CHART" -n "$ns" --create-namespace --version "$ACK_DDB_VERSION" --wait "${args[@]}" >/dev/null ||
    { warn_events "$ns"; die "ACK DynamoDB $ACK_DDB_VERSION did not become ready"; }
  ok "ACK DynamoDB $ACK_DDB_VERSION ${action}ed"
  [[ -z "${AWS_CREDENTIALS_FILE:-}${AWS_ENDPOINT_URL:-}" ]] &&
    warn "no AWS credentials or endpoint: tables are accepted but stay ACK.ResourceSynced=False"
  return 0
}

cmd_check() {
  current_ctx
  say "Checking $CTX"
  local vc cn ak
  vc=$(found_vela_core); cn=$(found_cnpg); ak=$(found_ack)
  [[ "${vc%% *}" == "$VELA_CORE_VERSION" ]] && ok "vela-core $vc" || bad "vela-core ${vc:-not installed}; the demo pins $VELA_CORE_VERSION"
  [[ "${cn%% *}" == "$CNPG_VERSION" ]] && ok "CloudNativePG $cn" || bad "CloudNativePG ${cn:-not installed}; the demo pins $CNPG_VERSION"
  [[ -z "$ak" ]] && ok "no ACK installed (act 4 opens without it)" || bad "ACK found ($ak); act 4 opens without it: ./demo-init-kubecon.sh reset"
  if k get events -A --field-selector type=Warning -o jsonpath='{.items[*].message}' 2>/dev/null | has 'x509: certificate signed by unknown authority'; then
    bad "image pulls fail with x509 errors: set CA_BUNDLE and run ./demo-init-kubecon.sh up"
  else
    ok "no image pulls failing on certificates"
  fi
  if k get nodes -o jsonpath='{range .items[*]}{.spec.taints[*].key}{"\n"}{end}' | has disk-pressure; then
    bad "a node has disk pressure: free Docker disk, then delete Failed pods"
  else
    ok "no node has disk pressure"
  fi
  [[ "$(k -n vela-system get deploy -l controller.oam.dev/name=vela-core -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null)" -ge 1 ]] 2>/dev/null &&
    ok "vela-core ready" || bad "vela-core has no ready replicas"
  [[ "$(k -n cnpg-system get deploy cnpg-controller-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" -ge 1 ]] 2>/dev/null &&
    ok "CloudNativePG operator ready" || bad "CloudNativePG operator not ready"
  "$VELA" def list 2>/dev/null | has -E '^\s*(postgres|dynamodb-table)\s' && bad "a postgres or dynamodb-table definition is installed: ./demo-init-kubecon.sh reset" || ok "no postgres or dynamodb-table definition"
  "$VELA" ls -n petclinic 2>/dev/null | has petclinic && bad "petclinic already exists: ./demo-init-kubecon.sh reset" || ok "petclinic namespace is empty"
  "$VELA" status shop -n team-a 2>/dev/null | has -i healthy && ok "shop is healthy" || bad "shop is not healthy"
  "$VELA" ls -n team-a 2>/dev/null | grep broken | has -i unhealthy && ok "broken is unhealthy, as act 1 needs" || bad "broken is not in its unhealthy state yet"
  if is_k3d_ctx; then
    for img in "${PRELOAD_IMAGES[@]}"; do
      docker exec "${CTX#k3d-}-agent-0" crictl images 2>/dev/null | has "${img%%:*}" && ok "image $img on the nodes" || bad "image $img not preloaded"
    done
  fi
  check_vela_build && ok "$VELA is the demo build" || bad "$VELA is not the demo build: $VELA_BUILD_PROBLEM"
  [[ -d "$LIVE_DIR" && -z "$(live_dir_work)" ]] && ok "$LIVE_DIR is empty" || bad "$LIVE_DIR is missing or not empty"
  return "$FAILED"
}

# live_dir_work lists what the agent made in LIVE_DIR; the skill links run puts there
# (.claude, .agents) and the client's own files (.mcp.json) do not count.
live_dir_work() {
  ls -A "$LIVE_DIR" 2>/dev/null | grep -vxE '\.claude|\.agents|\.mcp\.json' || true
}

cmd_reset() {
  current_ctx
  say "Resetting the demo on $CTX"
  reset_demo_work
  "$VELA" delete floci -n floci -y >/dev/null 2>&1 || true
  ok "reset; run ./demo-init-kubecon.sh check"
}

# reset_demo_work removes what the acts create and act 4's ACK, keeping the cluster,
# vela-core, CloudNativePG and Floci.
reset_demo_work() {
  "$VELA" delete petclinic -n petclinic -y >/dev/null 2>&1 || true
  for app in $("$VELA" ls -n orders 2>/dev/null | awk 'NR>1 && $1!="" {print $1}'); do "$VELA" delete "$app" -n orders -y >/dev/null 2>&1 || true; done
  # vela def del asks for confirmation even with -y, so the answer is piped in.
  echo yes | "$VELA" def del postgres -t component >/dev/null 2>&1 || true
  echo yes | "$VELA" def del dynamodb-table -t component >/dev/null 2>&1 || true
  local ak
  ak=$(found_ack)
  if [[ "$ak" == *helm:* ]]; then
    local r=${ak##*helm:}
    h uninstall "${r%@*}" -n "${r#*@}" >/dev/null 2>&1 || true
  fi
  # Only the DynamoDB CRDs: this cluster is shared with the bucket demo, whose ACK S3 CRDs stay.
  k get crd -o name | grep dynamodb.services.k8s.aws | xargs -r kubectl --context "$CTX" delete >/dev/null 2>&1 || true
  k -n ack-system delete secret ack-aws-credentials >/dev/null 2>&1 || true
  k delete pod -A --field-selector=status.phase=Failed >/dev/null 2>&1 || true
  if [[ -d "$LIVE_DIR" ]]; then
    find "$LIVE_DIR" -mindepth 1 -maxdepth 1 ! -name .claude ! -name .agents ! -name .mcp.json -exec rm -rf {} + 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------- run: the guided demo

# enter_demo_dir works in ./kubevela-demo, unless the current folder already is one.
enter_demo_dir() {
  if [[ "$(basename "$PWD")" != kubevela-demo ]]; then
    mkdir -p kubevela-demo
    cd kubevela-demo
  fi
  DEMO_DIR=$PWD
  LIVE_DIR=${LIVE_DIR_GIVEN:-$DEMO_DIR/live}
  say "Working in $DEMO_DIR"
}

# ensure_vela_cli checks the vela binary in ~/workspace/kubevela/bin (or VELA). This copy
# never clones or builds kubevela: the binary must already have the mcp and def commands.
ensure_vela_cli() {
  say "vela CLI: $VELA"
  [[ -x "$VELA" ]] || die "no vela binary at $VELA: build kubevela master there (make vela-cli), or set VELA"
  check_vela_build || die "$VELA is not the demo build: $VELA_BUILD_PROBLEM"
  ok "$VELA has the commands the demo needs"
}

# ensure_skills clones kubevela/skills, or fast-forwards an existing clone.
ensure_skills() {
  say "kubevela/skills"
  local dst=$DEMO_DIR/skills
  if [[ ! -e "$dst/.git" ]]; then
    git clone -q "$SKILLS_REPO" "$dst"
    ok "cloned $SKILLS_REPO"
  else
    git -C "$dst" pull -q --ff-only || warn "could not fast-forward $dst; using it as it is"
    ok "skills at $(git -C "$dst" log -1 --format=%h)"
  fi
}

# prepare_live_dir links the skills into the agent's folder for Claude Code
# (.claude/skills) and Codex (.agents/skills), so nothing is installed for the user.
prepare_live_dir() {
  say "Agent folder $LIVE_DIR"
  local s
  mkdir -p "$LIVE_DIR/.claude/skills" "$LIVE_DIR/.agents/skills"
  for s in "${SKILLS[@]}"; do
    ln -sfn "$DEMO_DIR/skills/$s" "$LIVE_DIR/.claude/skills/$s"
    ln -sfn "$DEMO_DIR/skills/$s" "$LIVE_DIR/.agents/skills/$s"
  done
  ok "skills linked: ${SKILLS[*]}"
}

# clear_leftovers removes what an earlier rehearsal left, after asking.
clear_leftovers() {
  say "Leftovers from an earlier run"
  local found=""   # a string, not an array: bash 3.2 calls an empty array unbound
  k -n petclinic get app petclinic >/dev/null 2>&1 && found+="  found: Application petclinic/petclinic"$'\n'
  [[ -n "$(k -n orders get app -o name 2>/dev/null)" ]] && found+="  found: Applications in orders"$'\n'
  k -n vela-system get comp postgres >/dev/null 2>&1 && found+="  found: ComponentDefinition postgres"$'\n'
  k -n vela-system get comp dynamodb-table >/dev/null 2>&1 && found+="  found: ComponentDefinition dynamodb-table"$'\n'
  [[ -n "$(found_ack)" ]] && found+="  found: ACK DynamoDB (act 4 opens without it)"$'\n'
  [[ -n "$(live_dir_work)" ]] && found+="  found: files in $LIVE_DIR"$'\n'
  if [[ -z "$found" ]]; then ok "none"; return 0; fi
  printf '%s' "$found"
  if (( ! ASSUME_YES )); then
    read -r -p "  Remove them so the acts start clean? [Y/n] " answer </dev/tty
    [[ "$answer" =~ ^[Nn] ]] && { warn "kept; the acts may not start from a clean state"; return 0; }
  fi
  reset_demo_work
  ok "removed"
}

# Pods that are fine: Running with every container ready, Succeeded, a Failed pod of a
# Job (the Job retries), and act 1's broken app, which crash-loops on purpose.
read -r -d '' POD_FILTER <<'PY' || true
import json, sys
for p in json.load(sys.stdin)["items"]:
    md, st = p["metadata"], p.get("status", {})
    if md.get("deletionTimestamp"):
        continue
    if md["namespace"] == "team-a" and md.get("labels", {}).get("app.oam.dev/name") == "broken":
        continue
    phase = st.get("phase", "")
    if phase == "Succeeded" or st.get("reason") == "Evicted":
        continue
    if phase == "Failed" and any(o.get("kind") == "Job" for o in md.get("ownerReferences", [])):
        continue
    cs = st.get("containerStatuses", [])
    if phase == "Running" and cs and all(c.get("ready") for c in cs):
        continue
    why = phase or "Unknown"
    for c in st.get("initContainerStatuses", []) + cs:
        w = c.get("state", {}).get("waiting")
        if w:
            why = w.get("reason", why)
            break
    print(md["namespace"], md["name"], why)
PY

# wait_pods waits until every pod is fine, or fails after WAIT_TIMEOUT seconds.
wait_pods() {
  say "Waiting for every pod (up to $WAIT_TIMEOUT seconds)"
  local deadline=$((SECONDS + WAIT_TIMEOUT)) pending="" ns
  clear_evicted
  if k get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="DiskPressure")].status}' | has True; then
    warn "a node reports DiskPressure: pods are rejected until it clears; ./demo-init-kubecon.sh diag says why"
  fi
  while :; do
    pending=$(k get pods -A -o json | python3 -c "$POD_FILTER")
    if [[ -z "$pending" ]]; then
      ok "all pods running (act 1's broken app crash-loops, as it should)"
      return 0
    fi
    (( SECONDS >= deadline )) && break
    sleep 5
  done
  echo "  not running after $WAIT_TIMEOUT seconds:" >&2
  sed 's/^/    /' <<<"$pending" >&2
  for ns in $(awk '{print $1}' <<<"$pending" | sort -u); do warn_events "$ns"; done
  die "Fix the pods above and run $SELF again; it picks up where the cluster is."
}

# clear_evicted deletes evicted pods; their controllers have already replaced them.
clear_evicted() {
  local names
  names=$(k get pods -A --field-selector=status.phase=Failed \
    -o jsonpath='{range .items[?(@.status.reason=="Evicted")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  [[ -z "$names" ]] && return 0
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && k -n "${line%%/*}" delete pod "${line#*/}" --wait=false >/dev/null 2>&1 || true
  done <<<"$names"
  ok "deleted $(grep -c . <<<"$names") evicted pods"
}

hr() { printf '\033[2m%s\033[0m\n' '------------------------------------------------------------------------'; }
title() { printf '\n'; hr; printf '\033[1;36m  %s\033[0m\n' "$*"; hr; }
prompt_text() {
  local line
  printf '\n  \033[1mPrompt:\033[0m\n'
  while IFS= read -r line; do printf '    \033[33m%s\033[0m\n' "$line"; done < <(fold -s -w 76 <<<"$*")
  printf '\n'
}
pause() { printf '\n\033[2m  %s \033[0m' "${1:-Press Enter to continue}"; read -r _ </dev/tty; }
k9s_hint() {
  command -v k9s >/dev/null 2>&1 && return 0
  warn "k9s is not installed (brew install k9s); the k9s steps below need it"
}

show_mcp_setup() {
  local cmdline json envargs kubeconfig_note=""
  envargs=$(mcp_env_args)
  cmdline=$("$VELA" mcp config --format command --allow-write --direct-namespace petclinic)
  json=$("$VELA" mcp config --allow-write --direct-namespace petclinic)
  if [[ -n "${KUBECONFIG:-}" ]]; then
    printf -v kubeconfig_note "The cluster's kubeconfig is not your default one, so every terminal that talks to it\n  needs:  export KUBECONFIG=%s" "$KUBECONFIG"
  fi
  title "Connect your agent to the kubevela MCP server"
  cat <<EOF

  The server reads the cluster through the kubeconfig and context below, now $CTX.
  Writes are allowed; direct (confirmed) applies only in the petclinic namespace.
  $kubeconfig_note

  Claude Code (remove an older kubevela entry first, so this binary is the one used):
    claude mcp remove --scope user kubevela 2>/dev/null; claude mcp add --scope user $envargs kubevela -- $cmdline

  Codex:
    codex mcp remove kubevela 2>/dev/null; codex mcp add $envargs kubevela -- $cmdline
  or put this table in ~/.codex/config.toml:
EOF
  python3 -c 'import json,os,sys
s = json.loads(sys.argv[1])["mcpServers"]["kubevela"]
print("    [mcp_servers.kubevela]")
print("    command = " + json.dumps(s["command"]))
print("    args = " + json.dumps(s["args"]))
if os.environ.get("KUBECONFIG"):
    print("    [mcp_servers.kubevela.env]")
    print("    KUBECONFIG = " + json.dumps(os.environ["KUBECONFIG"]))' "$json"
  cat <<EOF

  Then start the agent in the folder the skills are linked into:
    cd $LIVE_DIR && GOWORK=off claude        # or: GOWORK=off codex
  GOWORK=off keeps a go.work in a parent folder out of the agent's go mod tidy and go test.
  Check that kubevela is connected with /mcp, and that the kubevela-* skills are listed.

  Keep k9s open in a second terminal, on the same cluster:
    KUBECONFIG=${KUBECONFIG:-~/.kube/config} k9s --context $CTX
EOF
  k9s_hint
  printf '\n  Acts 2 and 3 apply in direct mode, which asks you to confirm in the client. A client\n'
  printf '  without MCP elicitation gets YAML instead; apply it with: %s up -f <file>\n' "$VELA"
}

act1() {
  title "Act 1 · Debug: why is broken unhealthy?"
  printf '\n  In k9s:  :ns team-a  then  :app  (shop and broken),  :pods  (broken in CrashLoopBackOff)\n'
  prompt_text "Why is the broken application in team-a not healthy?"
  cat <<'EOF'
  Expect the tools: get_platform_info, explain_application, get_logs with previous: true.
  Verify:
    - findings ordered by severity, each citing its object (Deployment broken, the Pod,
      the BackOff event), with the cluster's own text under observed
    - the previous container's log says DB_URL not set, and the agent names the
      property to set
    - meta names the vela-core and Kubernetes versions and when it was read
  In k9s: on the broken pod press  l  for logs, then  p  for the previous container.
EOF
  prompt_text "Where can I reach the shop application?"
  cat <<'EOF'
  Verify: endpoints lists http://shop.team-a, internal, from Service team-a/shop.
EOF
}

act2() {
  title "Act 2 · Petclinic on its built-in H2 database"
  printf '\n  In k9s:  :ns petclinic  then  :app  (empty now; petclinic appears after the apply)\n'
  prompt_text "Using the kubevela-developer skill, deploy Spring Petclinic to the petclinic namespace with the image $PETCLINIC_IMAGE on port 8080. Keep its default in-memory database for now."
  cat <<EOF
  Expect: get_platform_info, list_definitions, describe_definition webservice, a draft,
  dryrun_application, diff_application, then apply_application with a confirmation.
  Verify:
    - the diff lists a Deployment and a Service, risk LOW, from the server
    - accept the confirmation the server wrote from the diff
    - in k9s  :app  shows petclinic running, and  :pods  a ready petclinic pod
  Lose the data:
    $VELA port-forward petclinic -n petclinic 8080:8080
  Open http://localhost:8080 and add an owner. In k9s  :deploy , select petclinic, press  r
  to restart it, port-forward again and refresh: the owner is gone. H2 lives in memory.
EOF
}

act3a() {
  title "Act 3a · The platform engineer writes a Postgres component on CloudNativePG"
  printf '\n  In k9s:  :crd  then filter  /cnpg  (the clusters.postgresql.cnpg.io CRD the agent reads)\n'
  prompt_text "Using the kubevela-defkit-author skill, create a defkit module called postgres-cnpg with a component named postgres that provisions a PostgreSQL cluster with CloudNativePG. Developers should only choose the number of instances, the storage size, and the database name. Build the parameters from the CRD installed on this cluster."
  cat <<'EOF'
  Expect, in order: list_definitions and describe_definition, vela def init-module,
  the CRD read, Go with defkit, go test ./..., vela def validate-module and gen-module,
  then dryrun_application with the generated definition, and again with serverCheck.
  Verify against the CRD:
    - postgresql.cnpg.io/v1 Cluster; instances is the only required field
    - storage at spec.storage.size; database and owner under spec.bootstrap.initdb
    - the cluster is named after the component, so its Secret is <component>-app
    - health from status.readyInstances (or the Ready condition)
EOF
  prompt_text "Apply the module to this cluster and show me the schema developers will see."
  cat <<'EOF'
  Verify: vela def apply-module postgres-cnpg, then describe_definition postgres with
  three parameters and their usage strings. In k9s  :comp  in vela-system lists postgres.
EOF
}

act3b() {
  title "Act 3b · The developer moves Petclinic onto Postgres"
  printf '\n  In k9s:  :ns petclinic  then  :clusters.postgresql.cnpg.io ,  :pods ,  :secrets\n'
  prompt_text "Using the kubevela-developer skill, add a postgres database from our new postgres component to the existing petclinic application, and switch Petclinic to it so its data survives restarts. Wire the connection through the Secret the database creates."
  cat <<'EOF'
  Expect: get_application petclinic, describe_definition postgres, dryrun_application,
  diff_application against the running Application, then apply_application.
  Verify:
    - the diff adds the CNPG Cluster and modifies the Deployment's env; risk MEDIUM
    - SPRING_PROFILES_ACTIVE=postgres; POSTGRES_URL, POSTGRES_USER and POSTGRES_PASS
      come from Secret <db>-app keys jdbc-uri, username and password via secretKeyRef,
      never as literals
    - petclinic dependsOn the database
    - in k9s the <db>-1 pod starts, the <db>-app Secret appears, then petclinic restarts
  If it is slow, ask: "Why isn't petclinic healthy yet?"
  Persistence: port-forward, add an owner, restart the deployment in k9s ( :deploy , r ),
  port-forward again and refresh. The owner is still there, in Postgres.
EOF
}

# The checks after each act only report; the presenter decides whether to go on.
check_act2() {
  [[ "$(k -n petclinic get app petclinic -o jsonpath='{.status.status}' 2>/dev/null)" == running ]] &&
    ok "petclinic is running" || warn "petclinic is not running yet (ask the agent: why isn't petclinic healthy?)"
}

check_act3a() {
  k -n vela-system get comp postgres >/dev/null 2>&1 &&
    ok "ComponentDefinition postgres is installed" || warn "no ComponentDefinition postgres yet; act 3b needs it"
}

check_act3b() {
  local types ready
  types=$(k -n petclinic get app petclinic -o jsonpath='{.spec.components[*].type}' 2>/dev/null)
  [[ " $types " == *" postgres "* ]] && ok "petclinic has a postgres component" || warn "petclinic has no postgres component"
  ready=$(k -n petclinic get clusters.postgresql.cnpg.io -o jsonpath='{.items[*].status.readyInstances}' 2>/dev/null)
  [[ -n "$ready" && "$ready" != 0 ]] && ok "CNPG cluster ready instances: $ready" || warn "no ready CNPG instance in petclinic yet"
  [[ "$(k -n petclinic get app petclinic -o jsonpath='{.status.status}' 2>/dev/null)" == running ]] &&
    ok "petclinic is running" || warn "petclinic is not running yet"
}

cmd_run() {
  enter_demo_dir
  ensure_vela_cli
  ensure_skills
  (( MODE_GIVEN )) || MODE=keep   # the cluster is shared with the other demo: change nothing unasked
  preflight
  choose_context
  ensure_vela_core
  ensure_cnpg
  clear_leftovers
  preload_images
  ensure_floci
  seed_act1
  warm_go_cache
  prepare_live_dir
  wait_pods
  show_mcp_setup
  pause "Press Enter when the agent is running in $LIVE_DIR with kubevela connected"
  act1
  pause "Press Enter once you have verified act 1"
  act2
  pause "Press Enter once you have verified act 2"
  check_act2
  act3a
  pause "Press Enter once the postgres component is applied"
  check_act3a
  act3b
  pause "Press Enter once you have verified act 3"
  check_act3b
  title "Done"
  cat <<EOF

  Act 4 (DynamoDB) opens without ACK: see demo-script.md, and install it live with
    $SELF ack --floci
  Reset for another rehearsal (keeps the cluster):  $SELF reset
EOF
}

# cmd_diag explains evictions: the kubelet's own message on each evicted pod, the
# nodes' pressure conditions and usage, and what the Docker VM has to give.
cmd_diag() {
  current_ctx
  say "Evicted pods on $CTX (the message names the resource that ran short)"
  k get pods -A --field-selector=status.phase=Failed -o json | python3 -c '
import collections, json, re, sys
items = [p for p in json.load(sys.stdin)["items"] if p.get("status", {}).get("reason") == "Evicted"]
if not items:
    print("  none")
why = collections.Counter()
for p in items:
    msg = p["status"].get("message", "")
    m = re.match(r"The node was low on resource: \[?([\w.-]+)", msg)
    c = re.search(r"The node had condition: \[(\w+)\]", msg)
    what = "low on " + m.group(1).rstrip(".") if m else "rejected: node had " + c.group(1) if c else msg[:80]
    why[(p["spec"].get("nodeName", "?"), what)] += 1
for (node, what), n in why.most_common():
    print("  %3d pods on %s: %s" % (n, node, what))
'
  say "Node pressure"
  k get nodes -o json | python3 -c '
import json, sys
for n in json.load(sys.stdin)["items"]:
    c = {x["type"]: x["status"] for x in n["status"]["conditions"]}
    p = [t for t in ("MemoryPressure", "DiskPressure", "PIDPressure") if c.get(t) == "True"]
    a = n["status"]["allocatable"]
    print("  %s: %s; allocatable cpu %s, memory %s" % (n["metadata"]["name"], ", ".join(p) or "no pressure", a["cpu"], a["memory"]))
'
  k top nodes 2>/dev/null | sed 's/^/  /' || warn "metrics not available yet (k top nodes)"
  say "Docker VM (all k3d nodes share it)"
  docker info --format '  {{.NCPU}} CPUs, {{printf "%.1f" (divf .MemTotal 1073741824)}} GiB memory' 2>/dev/null ||
    docker info --format '  {{.NCPU}} CPUs, {{.MemTotal}} bytes memory'
  docker run --rm busybox:1.36 df -h / 2>/dev/null | awk 'NR==2 {print "  disk: " $4 " free of " $2 " (" $5 " used)"}'
  docker system df 2>/dev/null | sed 's/^/  /'
  if is_k3d_ctx; then
    say "Disk inside each k3d node"
    local n
    for n in $(k3d node list --no-headers 2>/dev/null | awk -v c="${CTX#k3d-}" '$3==c && $2!="loadbalancer" {print $1}'); do
      docker exec "$n" df -h /var/lib/rancher 2>/dev/null | awk -v n="$n" 'NR==2 {print "  " n ": " $4 " free of " $2}'
    done
    say "The kubelet's last eviction signal on each node"
    for n in $(k3d node list --no-headers 2>/dev/null | awk -v c="${CTX#k3d-}" '$3==c && $2!="loadbalancer" {print $1}'); do
      docker logs --since 2h "$n" 2>&1 | grep -E 'eviction_manager.*(Eviction manager: attempting to reclaim|thresholds|observations)' |
        tail -1 | sed -E 's/.*(resourceName="[^"]+").*/\1/; s/^/  '"$n"': /' | cut -c1-220
    done
    echo "  (resourceName names the signal; none printed means no eviction in the last 2 hours)"
  fi
  cat <<'EOF'

  The demo needs about 4 CPUs, 8 GiB of memory and 30 GiB of free disk in the VM.
  Low on memory: raise the VM's memory (Rancher Desktop: Preferences > Virtual Machine).
  Low on disk (ephemeral-storage, imagefs, nodefs, or a DiskPressure rejection): clear what
    nothing uses, or recreate the cluster with kubevela-bucket-floci-demo/clean.sh and demo.sh --cluster-only:
      docker volume ls -f dangling=true; docker volume prune; docker image prune -a
      ./demo-init-kubecon.sh reset
EOF
}

cmd_down() {
  die "This copy does not delete clusters; $CLUSTER belongs to demo.sh. Remove it with: kubevela-bucket-floci-demo/clean.sh"
}

sub=run
case "${1:-}" in
  -h | --help) sub=help; shift ;;
  -* | "") ;;
  *) sub=$1; shift ;;
esac
parse_flags "$@"
case "$sub" in
  run) cmd_run ;;
  up) cmd_up ;;
  ack) cmd_ack ;;
  check) cmd_check ;;
  diag) cmd_diag ;;
  reset) cmd_reset ;;
  down) cmd_down ;;
  *) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 2 ;;
esac
