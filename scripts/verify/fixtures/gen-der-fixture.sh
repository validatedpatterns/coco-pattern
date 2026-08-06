#!/usr/bin/env bash
set -euo pipefail

# Generate an arbitrary .der certificate for DEL-4 cheap repro testing.
# This is NOT a real VCEK — it's a throwaway cert for byte-identity verification.
# Usage: ./gen-der-fixture.sh [output_path]
#   Default output: /tmp/fake.der

OUTPUT_PATH="${1:-/tmp/fake.der}"

# Assert openssl is present (RESEARCH marks this as required-no-fallback)
if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl not found in PATH"
  echo "openssl is required to generate DER fixtures."
  echo "Install openssl before running this script."
  exit 1
fi

# Generate a self-signed cert with 1-day validity, DER format
# Subject is clearly marked as a test fixture
openssl req -x509 -newkey rsa:2048 \
  -keyout /dev/null \
  -outform DER \
  -out "${OUTPUT_PATH}" \
  -days 1 \
  -nodes \
  -subj "/CN=coco-airgap-test" \
  >/dev/null 2>&1

if [ ! -f "${OUTPUT_PATH}" ]; then
  echo "ERROR: failed to generate DER fixture at ${OUTPUT_PATH}"
  exit 1
fi

echo "${OUTPUT_PATH}"
