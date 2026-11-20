#!/bin/sh
# Generates Substrate's CA pools and JWT pool into $OUT, one directory per
# secret, in the format kagent's installer writes (pkg/install/substrate_init.go):
#   CA pool: pool (JSON), tls.crt, tls.key        JWT pool: pool, jwks
# Runs in an openssl container. apply-pools.sh creates only the missing Secrets.
set -eu
OUT="${OUT:-/out}"
b64() { base64 -w0 "$1"; }
b64url() { base64 -w0 "$1" | tr '+/' '-_' | tr -d '='; }

# ca_pool <dir> <ed25519|p256>
ca_pool() {
    dir="$OUT/$1"; mkdir -p "$dir"
    case "$2" in
        ed25519) openssl genpkey -algorithm ED25519 -out "$dir/tls.key" ;;
        p256) openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$dir/tls.key" ;;
    esac
    openssl req -x509 -new -key "$dir/tls.key" -days 365 -subj "/CN=$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,digitalSignature,keyCertSign" \
        -out "$dir/tls.crt"
    openssl x509 -in "$dir/tls.crt" -outform DER -out "$dir/cert.der"
    openssl pkcs8 -topk8 -nocrypt -in "$dir/tls.key" -outform DER -out "$dir/key.der"
    printf '{"CAs":[{"ID":"1","SigningKeyPKCS8":"%s","RootCertificateDER":"%s"}],"ActiveForSigning":"1"}' \
        "$(b64 "$dir/key.der")" "$(b64 "$dir/cert.der")" > "$dir/pool"
    rm -f "$dir/cert.der" "$dir/key.der"
}

ca_pool actor-id-ca-pool ed25519
ca_pool egress-mitm-ca-pool p256
ca_pool service-dns-ca-pool ed25519
ca_pool pod-identity-ca-pool ed25519
ca_pool postgres-ca-pool ed25519

# actor-id-ca-certs: the actor identity CA root, PEM.
mkdir -p "$OUT/actor-id-ca-certs"
cp "$OUT/actor-id-ca-pool/tls.crt" "$OUT/actor-id-ca-certs/ca.crt"

# actor-id-jwt-pool: one ES256 authority, plus its public JWKS.
dir="$OUT/actor-id-jwt-pool"; mkdir -p "$dir"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$dir/key.pem"
openssl pkcs8 -topk8 -nocrypt -in "$dir/key.pem" -outform DER -out "$dir/key.der"
printf '{"Authorities":[{"ID":"1","Algorithm":"ES256","SigningKeyPKCS8":"%s"}],"ActiveForSigning":"1"}' \
    "$(b64 "$dir/key.der")" > "$dir/pool"
# Public point: the last 64 bytes of the SPKI DER are x||y.
openssl pkey -in "$dir/key.pem" -pubout -outform DER | tail -c 64 > "$dir/xy.bin"
head -c 32 "$dir/xy.bin" > "$dir/x.bin"; tail -c 32 "$dir/xy.bin" > "$dir/y.bin"
printf '{"keys":[{"kty":"EC","crv":"P-256","x":"%s","y":"%s","kid":"1","alg":"ES256","use":"sig"}]}' \
    "$(b64url "$dir/x.bin")" "$(b64url "$dir/y.bin")" > "$dir/jwks"
rm -f "$dir/key.pem" "$dir/key.der" "$dir/xy.bin" "$dir/x.bin" "$dir/y.bin"
echo "generated: $(ls "$OUT" | tr '\n' ' ')"
