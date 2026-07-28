#!/usr/bin/env bash
set -euo pipefail

# Collect VCEK URLs from AMD SEV-SNP nodes.
# Requires: KUBECONFIG set, oc access to cluster, snphost on nodes.
# Output: ~/.coco-pattern/snp-vcek/vcek-urls.txt

OUTDIR="${HOME}/.coco-pattern/snp-vcek"
URLFILE="${OUTDIR}/vcek-urls.txt"

mkdir -p "${OUTDIR}"

echo "Collecting VCEK URLs from SNP-capable nodes..."

NODES=$(oc get nodes -l "feature.node.kubernetes.io/cpu-security.sev.snp=true" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [ -z "${NODES}" ]; then
  echo "No nodes with cpu-security.sev.snp=true label found."
  echo "Trying all nodes..."
  NODES=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
fi

: > "${URLFILE}"
COUNT=0

for NODE in ${NODES}; do
  echo "  Node: ${NODE}"
  URL=$(oc debug "node/${NODE}" -- chroot /host snphost show vcek-url 2>/dev/null | grep -E "^https://kdsintf\.amd\.com" || true)

  if [ -z "${URL}" ]; then
    echo "    SKIP: snphost not available or not an SNP host"
    continue
  fi

  HWID=$(echo "${URL}" | grep -oP '[0-9a-fA-F]{64}' | tr '[:upper:]' '[:lower:]' | head -1)

  if [ -z "${HWID}" ]; then
    echo "    ERROR: could not extract hardware ID from URL: ${URL}"
    continue
  fi

  echo "${HWID} ${URL}" >> "${URLFILE}"
  echo "    HWID: ${HWID}"
  echo "    URL:  ${URL}"
  COUNT=$((COUNT + 1))
done

echo ""
echo "Collected ${COUNT} VCEK URL(s) → ${URLFILE}"

if [ "${COUNT}" -eq 0 ]; then
  echo "No SNP nodes found. Nothing to download."
  exit 1
fi

echo ""
echo "Next: transfer ${URLFILE} to an internet-connected machine and run:"
echo "  make snp-download-vcek"
