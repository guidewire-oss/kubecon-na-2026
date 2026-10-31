#!/bin/bash
# Shows, for each stage, the products its API returns and every object in the
# stage's bucket.
#
# Usage: ./show-buckets.sh [--create [picture]] [stage...]
#   --create  First add a product with a picture to each stage, through its
#             API, unless the stage already has one of that name. Without a
#             picture, each stage gets its own mug: aws-cue KubeVela,
#             aws-devkit Guidewire, aws-ack AWS, gcp-devkit Google Cloud
#             (sample/mug-<name>.*). .jpg, .png, .gif, .webp and .svg work.
#             demo.sh does this for each stage as it goes live.
#   With no stage, shows aws-cue, aws-devkit, aws-ack and gcp-devkit.
#
# It runs inside each stage's product-catalog-api pod, which already knows its
# bucket and has the S3 or Cloud Storage client for it, so nothing is needed
# locally but kubectl. The bucket browser (http://localhost:8081) shows the
# same buckets, pictures included.
set -euo pipefail

SAMPLES="$(dirname "$0")/sample"
CREATE=false PICTURE=""
if [ "${1:-}" = "--create" ]; then
    CREATE=true
    shift
    # Stage names have no dot or slash, so anything that does is a picture.
    case "${1:-}" in
        *.* | */*)
            [ -f "$1" ] || { echo "✗ $1 is not a file" >&2; exit 1; }
            PICTURE="$1"
            shift
            ;;
    esac
fi
STAGES="${*:-aws-cue aws-devkit aws-ack gcp-devkit}"

# The content type the API stores the picture under.
picture_type() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        *.jpg | *.jpeg) echo image/jpeg ;;
        *.png) echo image/png ;;
        *.gif) echo image/gif ;;
        *.webp) echo image/webp ;;
        *.svg) echo image/svg+xml ;;
        *) echo "✗ $1: use a .jpg, .png, .gif, .webp or .svg picture" >&2; exit 1 ;;
    esac
}

# A stage's own mug, sample/mug-<name>.* in any picture format, so a mug can
# be swapped for an official logo by dropping in a file of the same name.
# Other stages get sample/mug.svg.
stage_picture() {
    local name="" f
    case "$1" in
        aws-cue) name=kubevela ;;
        aws-devkit) name=guidewire ;;
        aws-ack) name=aws ;;
        gcp-devkit) name=gcp ;;
    esac
    if [ -n "$name" ]; then
        for f in "$SAMPLES/mug-$name".*; do
            [ -f "$f" ] && { echo "$f"; return; }
        done
    fi
    echo "$SAMPLES/mug.svg"
}

# Read by `python -` in the pod, from the app's directory, so storage.py
# imports. Each stage gets IMAGE_B64, IMAGE_TYPE and NAME set ahead of it.
read -r -d '' REPORT <<'PY' || true
import json, urllib.request
import storage

API = "http://localhost:8080/products"


def list_products():
    with urllib.request.urlopen(API, timeout=10) as resp:
        return json.load(resp)["products"]


# Once per stage: a stage that already has a product of this name keeps it.
if IMAGE_B64 and any(p.get("name") == NAME for p in list_products()):
    print(f"Already has {NAME}")
elif IMAGE_B64:
    body = json.dumps({"name": NAME, "price": 12, "image_data": IMAGE_B64,
                       "image_content_type": IMAGE_TYPE}).encode()
    request = urllib.request.Request(API, data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as resp:
        created = json.load(resp)
    print(f"Created {created['name']}: {created['image_key']}")

store = storage.build_object_store()
products = list_products()
print(f"{store.provider} bucket {store.bucket}")
print(f"GET /products: {len(products)} product(s)")
for p in sorted(products, key=lambda p: p.get("created_at", "")):
    print(f"  {p.get('created_at', '?')}  {p.get('name')}  price {p.get('price')}  id {p.get('id')}")
keys = store.list_keys("")
print(f"Bucket objects: {len(keys)}")
for key in sorted(keys):
    print(f"  {key}")
PY

for stage in $STAGES; do
    printf '\n=== %s ===\n' "$stage"
    if ! kubectl -n "$stage" get deploy/product-catalog-api >/dev/null 2>&1; then
        echo "Not deployed yet"
        continue
    fi
    image_b64="" image_type="" product=""
    if [ "$CREATE" = true ]; then
        picture="${PICTURE:-$(stage_picture "$stage")}"
        image_type="$(picture_type "$picture")"
        image_b64="$(base64 <"$picture" | tr -d '\n')"
        product="$(basename "${picture%.*}" | tr -cd "A-Za-z0-9 ._-")"
    fi
    printf 'IMAGE_B64 = "%s"\nIMAGE_TYPE = "%s"\nNAME = "%s (%s)"\n%s\n' \
        "$image_b64" "$image_type" "$product" "$stage" "$REPORT" |
        kubectl -n "$stage" exec -i deploy/product-catalog-api -- python - ||
        echo "✗ Couldn't query $stage"
done
