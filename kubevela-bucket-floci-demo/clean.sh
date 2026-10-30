#!/bin/bash
# Delete the demo's k3d cluster; everything demo.sh installed lives inside it.
# Also stops the VelaUX port-forward demo.sh started.
#
# Usage: ./clean.sh [--apps-only]
#   --apps-only  Keep the cluster; delete only the product-catalog application
#                (its buckets in every stage are deleted with it)
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kubevela-bucket-floci-demo}"

if [ "${1:-}" = "--apps-only" ]; then
    vela delete product-catalog -n default -y || true
    exit 0
fi

# demo.sh leaves VelaUX forwarded in the background.
FORWARD_PID="${TMPDIR:-/tmp}/$CLUSTER_NAME-velaux-forward.pid"
if [ -f "$FORWARD_PID" ]; then
    kill "$(cat "$FORWARD_PID")" 2>/dev/null || true
    rm -f "$FORWARD_PID"
fi
k3d cluster delete "$CLUSTER_NAME"
