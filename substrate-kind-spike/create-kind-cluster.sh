#!/bin/bash
# kind cluster for the Agent Substrate addon spike. Adapted from
# agent-substrate/substrate hack/create-kind-cluster.sh (v1.0.0), made
# self-contained and reachable from a dev container:
#   - the API server binds 0.0.0.0, not 127.0.0.1
#   - no local registry: install with ate-setup --image-repo (published images)
#   - no /dev/kvm or IPv6 handling: gVisor sandbox class only
#   - writes two kubeconfigs next to this script (gitignored):
#       substrate.kubeconfig            for the host
#       substrate.container.kubeconfig  for a dev container (host.docker.internal)
#
#   - --zscaler trusts a TLS-inspecting proxy's CA, as the floci demo does
#
# Usage: ./create-kind-cluster.sh [--zscaler]   (KIND_CLUSTER_NAME overrides "substrate")
#   --zscaler  Mount REGISTRY_CA_BUNDLE, or ~/zscaler/zscaler_root.crt, into every
#              node at /etc/ssl/certs/registry-ca.crt. containerd's Go TLS stack
#              reads every file in that directory, so image pulls through the
#              proxy work. It is only read at cluster creation. Pods that
#              download from the internet (the gVisor release assets) need the
#              CA in the pod too; that is handled where they are installed.
# Needs: docker, kind, kubectl. Tear down with ./delete-kind-cluster.sh.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER="${KIND_CLUSTER_NAME:-substrate}"
CONTEXT="kind-$CLUSTER"
REGISTRY_CA_BUNDLE="${REGISTRY_CA_BUNDLE:-}"
NODE_CA_PATH="/etc/ssl/certs/registry-ca.crt"

for arg in "$@"; do
    case "$arg" in
        --zscaler) REGISTRY_CA_BUNDLE="${REGISTRY_CA_BUNDLE:-$HOME/zscaler/zscaler_root.crt}" ;;
        *) echo "✗ unknown argument $arg" >&2; exit 1 ;;
    esac
done
if [ -n "$REGISTRY_CA_BUNDLE" ] && [ ! -f "$REGISTRY_CA_BUNDLE" ]; then
    echo "✗ REGISTRY_CA_BUNDLE $REGISTRY_CA_BUNDLE is not a file" >&2
    exit 1
fi

for tool in docker kind kubectl; do
    command -v "$tool" >/dev/null || { echo "✗ $tool not found on PATH" >&2; exit 1; }
done

ca_mount=""
if [ -n "$REGISTRY_CA_BUNDLE" ]; then
    ca_mount="  extraMounts:
  - hostPath: $REGISTRY_CA_BUNDLE
    containerPath: $NODE_CA_PATH
    readOnly: true"
fi

# Substrate needs PodCertificateRequest and ClusterTrustBundle (projected pod
# certificates), served as certificates.k8s.io/v1beta1.
cat > kind-config.yaml <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
${ca_mount}
featureGates:
  ClusterTrustBundle: true
  ClusterTrustBundleProjection: true
  PodCertificateRequest: true
runtimeConfig:
  "certificates.k8s.io/v1beta1": "true"
networking:
  apiServerAddress: "0.0.0.0"
  ipFamily: ipv4
kubeadmConfigPatches:
- |
  kind: KubeletConfiguration
  serializeImagePulls: false
  maxParallelImagePulls: 4
YAML

echo "Deleting existing kind cluster '$CLUSTER' if any..."
kind delete cluster --name "$CLUSTER" || true

echo "Creating kind cluster '$CLUSTER'..."
kind create cluster --name "$CLUSTER" --config kind-config.yaml --wait 120s

# gVisor loopback pod-to-pod networking needs proxy ARP on every node.
echo "Enabling proxy ARP on the nodes..."
for node in $(kind get nodes --name "$CLUSTER"); do
    docker exec "$node" sysctl net.ipv4.conf.all.proxy_arp=1
    docker exec "$node" sysctl -e net.ipv6.conf.all.proxy_ndp=1
done

echo "Writing kubeconfigs..."
kind get kubeconfig --name "$CLUSTER" > substrate.kubeconfig
port="$(kind get kubeconfig --name "$CLUSTER" | sed -n 's#.*server: https://[^:]*:\([0-9]*\).*#\1#p' | head -1)"
# localhost is a SAN on the API server cert, so tls-server-name keeps TLS valid
# when the dev container reaches the host through host.docker.internal.
sed -e "s#server: https://[^:]*:$port#server: https://host.docker.internal:$port#" \
    -e '/certificate-authority-data/a\
    tls-server-name: localhost
' \
    substrate.kubeconfig > substrate.container.kubeconfig

echo "Checking the certificates APIs..."
kubectl --kubeconfig substrate.kubeconfig api-resources | grep -E "podcertificaterequests|clustertrustbundles"

cat <<MSG

✓ Cluster '$CLUSTER' is ready (context $CONTEXT, API port $port).
  Host:       export KUBECONFIG=$PWD/substrate.kubeconfig
  Container:  KUBECONFIG=$PWD/substrate.container.kubeconfig
MSG
