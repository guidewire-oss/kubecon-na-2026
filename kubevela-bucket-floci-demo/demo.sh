#!/bin/bash
# Bucket demo on a local k3d cluster: one Application, promoted through four
# stages, each with a different bucket backing and the same properties:
#   aws-cue     bucket-aws-cue     S3 in Floci via Crossplane, definitions in CUE
#   aws-defkit  bucket-aws-defkit  S3 in Floci via Crossplane, definitions in Go (DefKit)
#   aws-ack     bucket-aws-ack     S3 in Floci via ACK, DefKit
#   gcp-defkit  bucket-gcp-defkit  Cloud Storage in floci-gcp via Crossplane, DefKit
# The workflow tests the product-catalog API at each stage and waits for
# approval before the next. As soon as the first stage is deployed, VelaUX is
# forwarded to localhost:8000 and the bucket browser, which shows every
# stage's bucket on one page, to localhost:8081.
#
# This creates the one cluster every demo in this repo uses: the k3d cluster kubecon
# (CLUSTER_NAME overrides it). vela1.12-preview-demo/00-setup.sh and mcp/demo-init-kubecon.sh
# reuse it and never create their own.
#
# Usage: ./demo.sh [--skip-cluster] [--cluster-only] [--skip-build] [--no-registry] [--reinstall] [--zscaler] [--auto-approve] [--open]
#   --skip-cluster  Use the current kubectl context instead of creating the k3d cluster
#   --cluster-only  Stop once the platform is ready (KubeVela, VelaUX, Crossplane, ACK,
#                   Floci, the definitions): no product-catalog image, app or promotion.
#                   For the 1.12 and MCP demos, which only need the cluster.
#   --skip-build    Don't build and import the product-catalog image (already in the cluster)
#   --zscaler       Trust a TLS-inspecting proxy's CA: REGISTRY_CA_BUNDLE, or
#                   ~/zscaler/zscaler_root.crt. Mounted into the k3d nodes at
#                   cluster creation and given to Crossplane and VelaUX.
#   --auto-approve  Promote without asking. Without a terminal, demo.sh always does.
#   --no-registry   Skip the local registry (see below): import product-catalog
#                   straight into the nodes and pull the rest from the internet
#   --reinstall     Upgrade KubeVela, VelaUX, Crossplane and ACK even if the right
#                   version is already installed (by default a rerun leaves them alone)
#   --open          On macOS, open VelaUX and the bucket browser in the default
#                   browser once they are forwarded.
#
# Local registries, two k3d registry containers that outlive the cluster
# (./clean.sh keeps them; ./clean.sh --purge-registry drops them):
#   $REGISTRY_NAME  holds product-catalog (localhost:$REGISTRY_PORT)
#   $DOCKERHUB_MIRROR_NAME  pull-through cache for docker.io: every Docker Hub
#       image the cluster pulls (floci, curl, VelaUX, vela-core, the k3s system
#       images...) is fetched from Docker Hub once, then served locally on
#       later cluster rebuilds
#
# Needs: docker, k3d, kubectl, helm, go, and the vela CLI matching VELA_VERSION.
# Tear down with ./clean.sh.
#
# VelaUX logs in as admin with VELAUX_ADMIN_PASSWORD (8-16 characters, at
# least one letter and one number).
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER_NAME="${CLUSTER_NAME:-kubecon}"
REGISTRY_CA_BUNDLE="${REGISTRY_CA_BUNDLE:-}"
# containerd's Go TLS stack reads every file in /etc/ssl/certs.
NODE_CA_PATH="/etc/ssl/certs/registry-ca.crt"
REGISTRY_NAME="${REGISTRY_NAME:-kubecon-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
# In the cluster the registry is k3d-<name>:<port>; from the host, localhost.
REGISTRY_IN_CLUSTER="k3d-$REGISTRY_NAME:$REGISTRY_PORT"
REGISTRY_FROM_HOST="localhost:$REGISTRY_PORT"
# Pull-through cache for docker.io, mirrored by every node's containerd.
DOCKERHUB_MIRROR_NAME="${DOCKERHUB_MIRROR_NAME:-kubecon-dockerhub}"
DOCKERHUB_MIRROR_PORT="${DOCKERHUB_MIRROR_PORT:-5001}"
DOCKERHUB_MIRROR_IN_CLUSTER="k3d-$DOCKERHUB_MIRROR_NAME:5000"
VELA_VERSION="v1.12.0-alpha.1"
CROSSPLANE_VERSION="2.4.3"
PROVIDER_AWS_VERSION="v1.23.2"
PROVIDER_GCP_VERSION="v3.1.0"
ACK_S3_VERSION="1.15.0"
FLOCI_URL="http://floci.floci-system.svc.cluster.local:4566"
CURL_IMAGE="curlimages/curl:8.22.0"
VELAUX_ADMIN_PASSWORD="${VELAUX_ADMIN_PASSWORD:-VelaUX12345}"
VELAUX_URL="http://velaux-server.vela-system:8000/api/v1"
VELAUX_LOCAL_PORT="${VELAUX_LOCAL_PORT:-8000}"
BROWSER_LOCAL_PORT="${BROWSER_LOCAL_PORT:-8081}"
# Each port-forward's pid and log go in <prefix>-<name>.pid and .log;
# clean.sh stops the forwards through the pidfiles.
FORWARD_PREFIX="${TMPDIR:-/tmp}/$CLUSTER_NAME-forward"
APP="product-catalog"
BROWSER="bucket-browser"
STAGES="aws-cue aws-defkit aws-ack gcp-defkit"

SKIP_CLUSTER=false
CLUSTER_ONLY=false
SKIP_BUILD=false
USE_REGISTRY=true
REINSTALL=false
AUTO_APPROVE=false
OPEN=false
for arg in "$@"; do
    case "$arg" in
        --skip-cluster) SKIP_CLUSTER=true ;;
        --cluster-only) CLUSTER_ONLY=true; SKIP_BUILD=true ;;
        --skip-build) SKIP_BUILD=true ;;
        --no-registry) USE_REGISTRY=false ;;
        --reinstall) REINSTALL=true ;;
        --zscaler) REGISTRY_CA_BUNDLE="${REGISTRY_CA_BUNDLE:-$HOME/zscaler/zscaler_root.crt}" ;;
        --auto-approve) AUTO_APPROVE=true ;;
        --open) OPEN=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done
[ -t 0 ] || AUTO_APPROVE=true

step() { printf '\n=== %s ===\n' "$1"; }

check_tools() {
    step "Checking tools"
    local tools="kubectl helm vela go"
    [ "$SKIP_CLUSTER" = true ] || tools="k3d $tools"
    [ "$SKIP_BUILD" = true ] || tools="docker k3d $tools"
    for tool in $tools; do
        command -v "$tool" >/dev/null || { echo "✗ $tool is not installed"; exit 1; }
    done
    # A stale GOROOT (say, from a removed gvm install) only shows up when go runs.
    if ! go version >/dev/null 2>&1; then
        echo "✗ go is installed but doesn't run:"
        go version || true
        exit 1
    fi
    if [ -n "$REGISTRY_CA_BUNDLE" ] && [ ! -f "$REGISTRY_CA_BUNDLE" ]; then
        echo "✗ REGISTRY_CA_BUNDLE $REGISTRY_CA_BUNDLE is not a file"
        exit 1
    fi
    local cli
    cli="$(vela version 2>/dev/null | awk '/CLI Version/{print $3}')"
    cli="v${cli#v}" # the CLI may or may not print the v
    if [ "$cli" != "$VELA_VERSION" ]; then
        echo "⚠ vela CLI is $cli, the demo pins $VELA_VERSION:"
        echo "  curl -fsSl https://kubevela.io/script/install.sh | bash -s $VELA_VERSION"
    fi
    echo "✓ $tools"
}

# A cluster created without the CA mount can't pull anything behind the proxy,
# and k3d can't add a volume to an existing cluster.
check_cluster_ca() {
    [ -n "$REGISTRY_CA_BUNDLE" ] && command -v docker >/dev/null || return 0
    if ! docker exec "k3d-$CLUSTER_NAME-server-0" test -f "$NODE_CA_PATH" 2>/dev/null; then
        echo "✗ $CLUSTER_NAME was created without the CA; run ./clean.sh and retry"
        exit 1
    fi
}

# Creates a k3d registry container unless it exists.
# Usage: create_registry <name> <port> [extra k3d args]
create_registry() {
    local name="$1" port="$2"
    shift 2
    if k3d registry list "k3d-$name" >/dev/null 2>&1; then
        echo "Registry $name already exists, reusing it"
        return 1
    fi
    k3d registry create "$name" --port "$port" "$@"
}

# The registries are their own containers, so they survive cluster deletes and
# keep their images. The Docker Hub cache needs the proxy CA to reach upstream.
ensure_registry() {
    [ "$USE_REGISTRY" = true ] || return 0
    step "Local registries"
    create_registry "$REGISTRY_NAME" "$REGISTRY_PORT" || true
    if create_registry "$DOCKERHUB_MIRROR_NAME" "$DOCKERHUB_MIRROR_PORT" \
        --proxy-remote-url https://registry-1.docker.io && [ -n "$REGISTRY_CA_BUNDLE" ]; then
        docker cp "$REGISTRY_CA_BUNDLE" "k3d-$DOCKERHUB_MIRROR_NAME:/etc/ssl/certs/registry-ca.crt"
        docker restart "k3d-$DOCKERHUB_MIRROR_NAME" >/dev/null
    fi
}

# Tells every node's containerd to pull docker.io images through the cache.
write_registries_config() {
    REGISTRIES_CONFIG="$(mktemp "${TMPDIR:-/tmp}/$CLUSTER_NAME-registries.XXXXXX")"
    printf 'mirrors:\n  "docker.io":\n    endpoint:\n      - http://%s\n' \
        "$DOCKERHUB_MIRROR_IN_CLUSTER" >"$REGISTRIES_CONFIG"
}

# The registry only helps if the cluster's nodes know it, and with --skip-build
# only if product-catalog is already in it. Otherwise fall back to the old
# behaviour (images already imported into the nodes) and say so.
resolve_registry() {
    [ "$USE_REGISTRY" = true ] || return 0
    # No docker (a dev container): the images are already in the cluster.
    command -v docker >/dev/null || { USE_REGISTRY=false; return 0; }
    local node="k3d-$CLUSTER_NAME-server-0"
    if ! docker exec "$node" grep -q "$DOCKERHUB_MIRROR_IN_CLUSTER" /etc/rancher/k3s/registries.yaml 2>/dev/null; then
        echo "⚠ $CLUSTER_NAME wasn't created with the local registries; using the images already in it (run ./clean.sh and rerun to switch)"
        USE_REGISTRY=false
    elif [ "$SKIP_BUILD" = true ] && ! docker manifest inspect --insecure "$REGISTRY_FROM_HOST/product-catalog:latest" >/dev/null 2>&1; then
        echo "⚠ product-catalog isn't in the registry yet; using the image already in the cluster (rerun without --skip-build to push it)"
        USE_REGISTRY=false
    fi
}

# Prints a manifest with product-catalog pointed at the local registry, or as is
# with --no-registry. Usage: render_manifest <file>
render_manifest() {
    if [ "$USE_REGISTRY" != true ]; then
        cat "$1"
        return
    fi
    sed -e "s#image: product-catalog:latest#image: $REGISTRY_IN_CLUSTER/product-catalog:latest#" "$1"
}

create_cluster() {
    step "Creating k3d cluster $CLUSTER_NAME"
    if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
        echo "Cluster already exists, reusing it"
        check_cluster_ca
        kubectl config use-context "k3d-$CLUSTER_NAME"
    else
        local volume=""
        if [ -n "$REGISTRY_CA_BUNDLE" ]; then
            volume="--volume=$REGISTRY_CA_BUNDLE:$NODE_CA_PATH:ro@server:*;agent:*"
        fi
        local registry=""
        if [ "$USE_REGISTRY" = true ]; then
            write_registries_config
            registry="--registry-use=$REGISTRY_IN_CLUSTER --registry-config=$REGISTRIES_CONFIG"
        fi
        k3d cluster create "$CLUSTER_NAME" --agents 2 --wait ${registry:+$registry} ${volume:+"$volume"}
    fi
    kubectl get nodes
}

# Pushes to the local registry, or imports into the cluster behind the current
# context (the demo cluster unless --skip-cluster picked another k3d cluster).
build_image() {
    step "Building product-catalog:latest"
    docker build -t product-catalog:latest app
    if [ "$USE_REGISTRY" = true ]; then
        docker tag product-catalog:latest "$REGISTRY_FROM_HOST/product-catalog:latest"
        docker push "$REGISTRY_FROM_HOST/product-catalog:latest"
    else
        local context cluster
        context="$(kubectl config current-context)"
        cluster="${context#k3d-}"
        if [ "$cluster" = "$context" ]; then
            echo "✗ $context is not a k3d context; load product-catalog:latest into it yourself and use --skip-build"
            exit 1
        fi
        k3d image import product-catalog:latest -c "$cluster"
    fi
    # On a rerun, pods already running the image keep the old build (the tag
    # doesn't change) until they restart: every stage's API and the browser.
    local ns name
    kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.template.spec.containers[0].image}{"\n"}{end}' |
        awk '$3 ~ /(^|\/)product-catalog:latest$/ {print $1, $2}' |
        while read -r ns name; do
            kubectl -n "$ns" rollout restart "deploy/$name"
        done
}

# True if the vela-core controller runs with every demo gate. With an
# argument, says which gate is on or off.
controller_has_gates() {
    local args gate
    args="$(kubectl get deploy kubevela-vela-core -n vela-system -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null)" || return 1
    for gate in EnableCelExpressions EnableAddonComponent EnableSourceAutoUpdate EnableDefinitionInheritance; do
        if ! printf '%s\n' "$args" | grep -q "$gate=true"; then
            [ -z "${1:-}" ] || echo "✗ $gate is not on"
            return 1
        fi
        [ -z "${1:-}" ] || echo "✓ $gate=true"
    done
}

# Helm 4 applies charts server-side and fails when another manager owns a
# field it sets (vela writes vela-addon-registry's .data.registries). Take
# those fields over; Helm 3 has no such flag and no such conflicts.
helm_force_flag() {
    helm upgrade --help 2>/dev/null | grep -q -- '--force-conflicts' && echo --force-conflicts || true
}

# True if helm release $1 in namespace $2 is at chart version $3 (any status:
# a release left "failed" by an earlier conflict is fine if its pods are up) and
# REINSTALL isn't set. Lets a rerun (--skip-cluster) leave a working install
# alone instead of upgrading it, which needs the internet and can fail midway.
release_current() {
    [ "${REINSTALL:-false}" = true ] && return 1
    local version
    helm list -n "$2" --all --filter "^$1\$" -q 2>/dev/null | grep -qx "$1" || return 1
    version="$(helm get metadata "$1" -n "$2" -o json 2>/dev/null | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
    [ "$version" = "$3" ]
}

install_kubevela() {
    if release_current kubevela vela-system "${VELA_VERSION#v}" && controller_has_gates &&
        kubectl -n vela-system rollout status deploy/kubevela-vela-core --timeout=60s >/dev/null 2>&1; then
        step "KubeVela $VELA_VERSION is already installed with the demo gates"
        return
    fi
    step "Installing KubeVela $VELA_VERSION with the demo gates"
    helm repo add kubevela https://kubevela.github.io/charts >/dev/null 2>&1 || true
    helm repo update kubevela >/dev/null
    helm upgrade --install kubevela kubevela/vela-core -n vela-system --create-namespace $(helm_force_flag) \
        --version "${VELA_VERSION#v}" --devel --wait=legacy --timeout 10m \
        --set featureGates.enableCelExpressions=true \
        --set featureGates.enableAddonComponent=true \
        --set featureGates.enableSourceAutoUpdate=true \
        --set featureGates.enableDefinitionInheritance=true

    step "Checking the controller has the gates"
    controller_has_gates verbose || exit 1
}

# VelaUX downloads the addon catalog itself, so behind the proxy it needs the
# CA too. The addon has no parameter for it, so add a storage trait to its
# server component. Re-enabling the addon drops the trait; the check below
# puts it back. The app only redeploys when publishVersion changes.
trust_ca_in_velaux() {
    [ -n "$REGISTRY_CA_BUNDLE" ] || return 0
    kubectl -n vela-system create configmap registry-ca-bundle \
        --from-file=ca-bundle.crt="$REGISTRY_CA_BUNDLE" --dry-run=client -o yaml | kubectl apply -f -
    local app="application/addon-velaux-prerelease" i=0 name
    for name in $(kubectl -n vela-system get "$app" -o jsonpath='{.spec.components[*].name}'); do
        [ "$name" = velaux-server ] && break
        i=$((i + 1))
    done
    if kubectl -n vela-system get "$app" -o jsonpath="{.spec.components[$i].traits[*].type}" | grep -qw storage; then
        return 0
    fi
    kubectl -n vela-system patch "$app" --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/components/$i/traits/-\",
        \"value\":{\"type\":\"storage\",\"properties\":{\"configMap\":[{\"name\":\"registry-ca-bundle\",
        \"mountOnly\":true,\"mountPath\":\"$NODE_CA_PATH\",\"subPath\":\"ca-bundle.crt\",\"readOnly\":true}]}}}]"
    kubectl -n vela-system annotate "$app" --overwrite "app.oam.dev/publishVersion=registry-ca-$(date +%s)"
    # Without this, rollout status can pass on the old pod before KubeVela
    # has updated the Deployment.
    kubectl -n vela-system wait --for=jsonpath='{.spec.template.spec.volumes[0].configMap.name}'=registry-ca-bundle \
        deploy/velaux-server --timeout=300s
}

# VelaUX imports CLI-deployed apps only once an admin exists, and drops for
# good any app it fails to import before then. So create the admin before
# deploying anything.
install_velaux() {
    step "Enabling prerelease VelaUX and creating its admin user"
    if [ "${REINSTALL:-false}" != true ] &&
        [ "$(kubectl -n vela-system get application/addon-velaux-prerelease -o jsonpath='{.status.status}' 2>/dev/null)" = running ]; then
        echo "VelaUX addon already enabled"
    else
        enable_velaux_addon
    fi
    trust_ca_in_velaux
    kubectl -n vela-system rollout status deploy/velaux-server --timeout=300s
    ensure_velaux_admin
}

enable_velaux_addon() {
    vela addon registry list | grep -q '^experimental' || \
        vela addon registry add experimental --type=helm --endpoint=https://kubevela.github.io/catalog/experimental
    # The CLI only picks stable addon versions unless a prerelease is named.
    vela addon enable velaux-prerelease --version "$VELA_VERSION"
}

ensure_velaux_admin() {
    if kubectl get --raw "/api/v1/namespaces/vela-system/services/velaux-server:8000/proxy/api/v1/auth/admin_configured" |
        grep -q '"configured": *true'; then
        echo "Admin already configured"
        return
    fi
    # PUT with a JSON body, which kubectl --raw can't send, so use a curl pod.
    # Escape the password for JSON: backslashes first, then quotes.
    local password="${VELAUX_ADMIN_PASSWORD//\\/\\\\}"
    password="${password//\"/\\\"}"
    kubectl run velaux-init-admin --rm -i --restart=Never --quiet --image="$CURL_IMAGE" -- \
        curl -sS --fail-with-body -X PUT -H 'Content-Type: application/json' \
        -d "{\"name\":\"admin\",\"password\":\"$password\",\"email\":\"admin@example.com\"}" \
        "$VELAUX_URL/auth/init_admin"
    echo ""
    echo "✓ VelaUX admin created"
}

install_crossplane() {
    step "Installing Crossplane $CROSSPLANE_VERSION with the S3 and Cloud Storage providers"
    local skip_helm=false
    release_current crossplane crossplane-system "$CROSSPLANE_VERSION" && skip_helm=true
    if [ "$skip_helm" != true ]; then
        helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
        helm repo update crossplane-stable
    fi
    # Crossplane pulls packages itself, outside containerd, so it needs the
    # proxy CA too. No arrays: macOS bash 3.2 fails on empty ones under set -u.
    local ca_args=""
    if [ -n "$REGISTRY_CA_BUNDLE" ]; then
        kubectl create namespace crossplane-system --dry-run=client -o yaml | kubectl apply -f -
        kubectl -n crossplane-system create configmap registry-ca-bundle \
            --from-file=ca-bundle.crt="$REGISTRY_CA_BUNDLE" --dry-run=client -o yaml | kubectl apply -f -
        ca_args="--set registryCaBundleConfig.name=registry-ca-bundle --set registryCaBundleConfig.key=ca-bundle.crt"
    fi
    if [ "$skip_helm" = true ]; then
        echo "Crossplane $CROSSPLANE_VERSION already installed"
    else
        # shellcheck disable=SC2086 # ca_args is a word list
        helm upgrade --install crossplane crossplane-stable/crossplane $(helm_force_flag) --version "$CROSSPLANE_VERSION" \
            --namespace crossplane-system --create-namespace --wait --timeout 10m $ca_args
    fi
    # The GCP ProviderConfig has no endpoint field, but the Terraform provider
    # inside reads GOOGLE_STORAGE_CUSTOM_ENDPOINT, so set it on the pod.
    kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-aws-s3
spec:
  package: xpkg.upbound.io/upbound/provider-aws-s3:$PROVIDER_AWS_VERSION
---
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: floci-gcp
spec:
  deploymentTemplate:
    spec:
      selector: {}
      template:
        spec:
          containers:
            - name: package-runtime
              env:
                - name: GOOGLE_STORAGE_CUSTOM_ENDPOINT
                  value: http://floci-gcp.floci-system.svc.cluster.local:4588/storage/v1/
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-gcp-storage
spec:
  package: xpkg.upbound.io/upbound/provider-gcp-storage:$PROVIDER_GCP_VERSION
  runtimeConfigRef:
    name: floci-gcp
EOF
}

connect_floci() {
    step "Pointing Crossplane at Floci and floci-gcp"
    kubectl -n floci-system rollout status deploy/floci --timeout=600s
    kubectl -n floci-system rollout status deploy/floci-gcp --timeout=600s
    kubectl wait --for=condition=healthy --timeout=600s \
        provider.pkg.crossplane.io/upbound-provider-aws-s3 provider.pkg.crossplane.io/upbound-provider-gcp-storage
    kubectl apply -f floci/providerconfigs.yaml
}

# ACK's S3 controller, pointed at Floci for S3 and for the STS call it makes
# at startup. Floci serves plain HTTP and no <bucket>.<host> virtual hosts,
# hence the unsafe-URL and path-style settings. Floci accepts any keys.
install_ack() {
    step "Installing the ACK S3 controller $ACK_S3_VERSION"
    if release_current ack-s3 ack-system "$ACK_S3_VERSION"; then
        echo "ACK S3 controller already installed"
        return
    fi
    kubectl create namespace ack-system --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n ack-system create secret generic floci-credentials \
        --from-literal=credentials="$(printf '[default]\naws_access_key_id = test\naws_secret_access_key = test\n')" \
        --dry-run=client -o yaml | kubectl apply -f -
    helm upgrade --install ack-s3 oci://public.ecr.aws/aws-controllers-k8s/s3-chart $(helm_force_flag) \
        --version "$ACK_S3_VERSION" --namespace ack-system --wait --timeout 10m \
        --set aws.region=us-west-2 \
        --set aws.endpoint_url="$FLOCI_URL" \
        --set aws.identity_endpoint_url="$FLOCI_URL" \
        --set aws.allow_unsafe_aws_endpoint_urls=true \
        --set aws.endpoint_use_path_style=true \
        --set aws.credentials.secretName=floci-credentials
}

# Both the CUE and the DefKit definitions go in: the aws-cue stage uses the
# CUE ones, the later stages the DefKit ones.
apply_definitions() {
    step "Applying the KubeVela definitions (CUE and DefKit)"
    vela def apply definitions/components/bucket-aws-cue.cue
    vela def apply definitions/traits/high-availability.cue
    vela def apply-module ./defkit --conflict overwrite
}

deploy_app() {
    step "Deploying $APP and the $BROWSER"
    # The topology policies don't create their namespaces, so make the stages'.
    for ns in $STAGES; do
        kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
    done
    # vela up reads a file, not stdin.
    local name dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/$CLUSTER_NAME-apps.XXXXXX")"
    for name in "$APP" "$BROWSER"; do
        render_manifest "apps/$name.yaml" >"$dir/$name.yaml"
        vela up -f "$dir/$name.yaml"
    done
    rm -rf "$dir"
}

# Prints a workflow step's phase, or nothing before the step starts.
step_phase() {
    kubectl get -n default "application/$APP" -o jsonpath="{.status.workflow.steps[?(@.name==\"$1\")].phase}"
}

# Waits for a workflow step to reach one of the phases in $2, failing if it
# fails.
wait_for_step() {
    local name="$1" want="$2" phase
    for _ in $(seq 180); do
        phase="$(step_phase "$name")"
        case " $want " in *" ${phase:-none} "*) return 0 ;; esac
        if [ "$phase" = failed ]; then
            echo "✗ workflow step $name failed:"
            vela status "$APP"
            exit 1
        fi
        sleep 5
    done
    echo "✗ workflow step $name is still ${phase:-pending} after 15 minutes"
    exit 1
}

# Forwards a service in the background, so it can be watched while the
# promotion runs. The forward outlives demo.sh; ./clean.sh stops it.
# With --open, opens the page in the default browser too.
# Usage: forward <name> <namespace> <service> <local-port> <service-port> <url> [note]
forward() {
    local name="$1" ns="$2" svc="$3" port="$4" target="$5" url="$6" msg="$6${7:+, $7}" pid
    local log="$FORWARD_PREFIX-$name.log" pidfile="$FORWARD_PREFIX-$name.pid"
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "$name is already forwarded: $msg"
        open_page "$url"
        return
    fi
    kubectl port-forward -n "$ns" "svc/$svc" "$port:$target" >"$log" 2>&1 &
    pid=$!
    echo "$pid" >"$pidfile"
    for _ in $(seq 20); do
        if grep -q Forwarding "$log"; then
            echo "✓ $name: $msg"
            open_page "$url"
            return
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    # Not fatal: the demo runs without it.
    echo "⚠ Couldn't forward $name to port $port (VELAUX_LOCAL_PORT and BROWSER_LOCAL_PORT pick others):"
    cat "$log"
}

# Only macOS: on Linux `open` can be another program (openvt).
open_page() {
    [ "$OPEN" = true ] || return 0
    if [ "$(uname)" = Darwin ]; then
        open "$1"
    else
        echo "  --open only works on macOS; open $1 yourself"
    fi
}

forward_velaux() {
    forward velaux vela-system velaux-server "$VELAUX_LOCAL_PORT" 8000 \
        "http://localhost:$VELAUX_LOCAL_PORT" "user admin, password $VELAUX_ADMIN_PASSWORD"
}

# The browser's Application was applied with the product-catalog one; by the
# time the first stage is deployed it is usually running.
forward_browser() {
    kubectl wait -n default --for=jsonpath='{.status.status}'=running "application/$BROWSER" --timeout=300s
    kubectl rollout status -n default "deploy/$BROWSER" --timeout=300s
    forward "$BROWSER" default "$BROWSER" "$BROWSER_LOCAL_PORT" 8080 "http://localhost:$BROWSER_LOCAL_PORT"
}

# Resumes the workflow at stage $2's approval, asking first unless
# --auto-approve. Does nothing if the approval already went through, as when
# demo.sh runs again on a promoted app.
approve() {
    local prev="$1" stage="$2"
    wait_for_step "approve-$stage" "suspending succeeded"
    [ "$(step_phase "approve-$stage")" = suspending ] || return 0
    if [ "$AUTO_APPROVE" = true ]; then
        echo "Approving $prev -> $stage"
    else
        read -r -p "Press Enter to promote $prev -> $stage (or run: vela workflow resume $APP) " _
    fi
    # Fine if someone resumed it in the meantime.
    vela workflow resume "$APP" || true
}

# Once the stage's test passes, gives its bucket a product with the stage's
# mug (sample/mug-<name>.svg: KubeVela, Guidewire, AWS, then Google Cloud), so
# the bucket browser has a picture to show.
check_stage() {
    step "Stage $1"
    wait_for_step "test-$1" succeeded
    echo "✓ $1: bucket product-images-$1 exists and the API stored a product in it"
    ./seed-products.sh "$1" | grep -E '^(Created|Already has)' ||
        echo "⚠ Couldn't add the sample picture to $1; try ./seed-products.sh $1"
}

promote() {
    local first="${STAGES%% *}" stage prev
    wait_for_step "deploy-$first" succeeded
    forward_velaux
    forward_browser
    check_stage "$first"
    prev="$first"
    for stage in ${STAGES#* }; do
        approve "$prev" "$stage"
        check_stage "$stage"
        prev="$stage"
    done
}

summary() {
    step "Done"
    vela status "$APP"
    echo ""
    kubectl get buckets.s3.aws.upbound.io,buckets.storage.gcp.upbound.io
    echo ""
    kubectl get buckets.s3.services.k8s.aws -A
    echo ""
    echo "VelaUX: http://localhost:$VELAUX_LOCAL_PORT, user admin, password $VELAUX_ADMIN_PASSWORD"
    echo "Bucket browser: http://localhost:$BROWSER_LOCAL_PORT"
}

check_tools
if [ "$SKIP_CLUSTER" = true ]; then
    step "Using current context $(kubectl config current-context)"
else
    ensure_registry
    create_cluster
fi
resolve_registry
[ "$SKIP_BUILD" = true ] || build_image
# Start the emulators first: their image pulls overlap the installs below.
kubectl apply -f floci/floci.yaml -f floci/floci-gcp.yaml
install_kubevela
install_velaux
install_crossplane
connect_floci
install_ack
apply_definitions
if [ "$CLUSTER_ONLY" = true ]; then
    forward_velaux
    step "Cluster $CLUSTER_NAME is ready"
    kubectl get nodes
    echo "Context k3d-$CLUSTER_NAME. VelaUX: http://localhost:$VELAUX_LOCAL_PORT, user admin, password $VELAUX_ADMIN_PASSWORD"
    echo "Deploy the bucket demo on it with: ./demo.sh --skip-cluster"
    exit 0
fi
deploy_app
promote
summary
