#!/usr/bin/env bash
set -euo pipefail

# Download VCEK certificates from AMD KDS.
# Requires: internet access, ~/.coco-pattern/snp-vcek/vcek-urls.txt from collect step.
# Output: ~/.coco-pattern/snp-vcek/<hwid>/vcek.der per node.

OUTDIR="${HOME}/.coco-pattern/snp-vcek"
URLFILE="${OUTDIR}/vcek-urls.txt"

if [ ! -f "${URLFILE}" ]; then
  echo "ERROR: ${URLFILE} not found."
  echo "Run 'make snp-collect-vcek-urls' on a cluster-connected machine first."
  exit 1
fi

echo "Downloading VCEK certificates from AMD KDS..."

COUNT=0
TOTAL=$(wc -l < "${URLFILE}")

while IFS=' ' read -r HWID URL; do
  [ -z "${HWID}" ] && continue
  COUNT=$((COUNT + 1))
  echo ""
  echo "  [${COUNT}/${TOTAL}] HWID: ${HWID}"

  CERTDIR="${OUTDIR}/${HWID}"
  mkdir -p "${CERTDIR}"

  # Extract processor model from URL path (e.g., Milan, Genoa, Turin)
  PRODUCT=$(echo "${URL}" | grep -oP 'vcek/v1/\K[^/]+')
  echo "    Product: ${PRODUCT}"

  # Download VCEK certificate
  echo "    Downloading VCEK..."
  if curl -fsSL -o "${CERTDIR}/vcek.der" "${URL}"; then
    echo "    OK: ${CERTDIR}/vcek.der"
  else
    echo "    ERROR: failed to download VCEK from ${URL}"
    continue
  fi

  # Download CA chain (ARK + ASK)
  CA_URL="https://kdsintf.amd.com/vcek/v1/${PRODUCT}/cert_chain"
  echo "    Downloading CA chain (ARK + ASK)..."
  if curl -fsSL -o "${CERTDIR}/cert_chain.pem" "${CA_URL}"; then
    echo "    OK: ${CERTDIR}/cert_chain.pem"
  else
    echo "    WARN: failed to download CA chain from ${CA_URL}"
  fi

  # Verify DER certificate
  if openssl x509 -inform DER -in "${CERTDIR}/vcek.der" -noout 2>/dev/null; then
    SUBJECT=$(openssl x509 -inform DER -in "${CERTDIR}/vcek.der" -subject -noout 2>/dev/null)
    echo "    Verified: ${SUBJECT}"
  else
    echo "    WARN: ${CERTDIR}/vcek.der is not a valid DER certificate"
  fi
done < "${URLFILE}"

echo ""
echo "Downloaded ${COUNT} VCEK certificate(s) to ${OUTDIR}/"
echo ""
echo "Next: run 'make snp-gen-overrides' to generate values override file."
