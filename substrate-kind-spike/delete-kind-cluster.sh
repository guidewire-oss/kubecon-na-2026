#!/bin/bash
# Deletes the kind cluster created by create-kind-cluster.sh.
set -euo pipefail
cd "$(dirname "$0")"
kind delete cluster --name "${KIND_CLUSTER_NAME:-substrate}"
rm -f substrate.kubeconfig substrate.container.kubeconfig kind-config.yaml
