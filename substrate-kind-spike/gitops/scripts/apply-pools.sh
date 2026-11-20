#!/bin/sh
# Creates the Secrets and ConfigMap Substrate needs, only when missing, so reruns
# and upgrades keep the existing keys. Reads what gen-pools.sh wrote to $OUT.
set -eu
OUT="${OUT:-/out}"
ATE=ate-system
PODCERT=podcertificate-controller-system

# ensure <namespace> <name> <type> <key>...   (each key is a file in $OUT/<name>)
ensure() {
    ns="$1"; name="$2"; type="$3"; shift 3
    if kubectl get secret -n "$ns" "$name" >/dev/null 2>&1; then
        echo "secret $ns/$name exists, keeping it"
        return
    fi
    args=""
    for key in "$@"; do args="$args --from-file=$key=$OUT/$name/$key"; done
    case "$type" in
        tls) kubectl create secret tls "$name" -n "$ns" --cert="$OUT/$name/tls.crt" --key="$OUT/$name/tls.key" --dry-run=client -o json \
                 | jq --rawfile pool "$OUT/$name/pool" '.data.pool = ($pool | @base64)' | kubectl create -f - ;;
        *) # shellcheck disable=SC2086
           kubectl create secret generic "$name" -n "$ns" $args ;;
    esac
}

ensure "$ATE" actor-id-jwt-pool generic pool jwks
ensure "$ATE" actor-id-ca-pool tls
ensure "$ATE" actor-id-ca-certs generic ca.crt
ensure "$ATE" egress-mitm-ca-pool tls
ensure "$PODCERT" service-dns-ca-pool tls
ensure "$PODCERT" pod-identity-ca-pool tls
ensure "$PODCERT" postgres-ca-pool tls

# The object store credentials the atelet and rustfs charts read. Chart defaults.
if ! kubectl get secret -n "$ATE" kagent-rustfs-credentials >/dev/null 2>&1; then
    kubectl create secret generic kagent-rustfs-credentials -n "$ATE" \
        --from-literal=AWS_ACCESS_KEY_ID=rustfsadmin --from-literal=AWS_SECRET_ACCESS_KEY=rustfsadmin
fi

# ate-api-authentication: trust the cluster's service account issuer.
if ! kubectl get configmap -n "$ATE" ate-api-authentication >/dev/null 2>&1; then
    issuer="$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)"
    auth="jwtProviders:
- name: kubernetes
  issuer: $issuer
  audiences: [api.$ATE.svc]"
    case "$issuer" in
        https://kubernetes.default.svc|https://kubernetes.default.svc.cluster.local)
            auth="$auth
  certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token" ;;
    esac
    kubectl create configmap ate-api-authentication -n "$ATE" --from-literal=authentication.yaml="$auth"
fi
echo "bootstrap complete"
