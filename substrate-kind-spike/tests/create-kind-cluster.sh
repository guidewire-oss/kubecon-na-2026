#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$root/create-kind-cluster.sh" "$tmp/create-kind-cluster.sh"

cat > "$tmp/bin/kind" <<'SH'
#!/bin/bash
case "$*" in
    "get nodes "*) printf '%s\n' 'substrate-control-plane' ;;
    "get kubeconfig "*)
        cat <<'YAML'
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: test-ca
    server: https://0.0.0.0:12345
  name: kind-substrate
YAML
        ;;
esac
SH
cat > "$tmp/bin/docker" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$tmp/bin/kubectl" <<'SH'
#!/bin/bash
printf '%s\n' 'podcertificaterequests certificates.k8s.io/v1beta1' \
    'clustertrustbundles certificates.k8s.io/v1beta1'
SH
chmod +x "$tmp/bin/"*
touch "$tmp/registry-ca.crt"

PATH="$tmp/bin:$PATH" REGISTRY_CA_BUNDLE="$tmp/registry-ca.crt" \
    bash "$tmp/create-kind-cluster.sh" --zscaler

grep -q '^    server: https://0.0.0.0:12345$' "$tmp/substrate.kubeconfig"
if grep -q 'tls-server-name' "$tmp/substrate.kubeconfig"; then
    printf '%s\n' 'FAIL: host kubeconfig was changed' >&2
    exit 1
fi
cat > "$tmp/expected.container.kubeconfig" <<'YAML'
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: test-ca
    tls-server-name: localhost
    server: https://host.docker.internal:12345
  name: kind-substrate
YAML
diff -u "$tmp/expected.container.kubeconfig" "$tmp/substrate.container.kubeconfig"
printf '%s\n' 'PASS: host and container kubeconfigs generated correctly'
