#!/usr/bin/env bash
# Detects a node with Intel TDX support for PCCS deployment.
# Usage: bash scripts/get-pccs-node.sh
NODE=$(oc get nodes -l intel.feature.node.kubernetes.io/tdx=true \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$NODE" ]; then
    echo "ERROR: No TDX-capable nodes found" >&2
    exit 1
fi
echo "$NODE"
