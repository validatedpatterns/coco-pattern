#!/usr/bin/env bash
# Uncomments the disconnected/airgap-only secrets in a generated
# values-secret file: registryCaCert and bootstrap_secrets
# (mirror-registry-helm-oci). Both are commented out by default in
# values-secret.yaml.template because they only apply to airgap
# (disconnected mirror) deployments and reference local files
# (~/.coco-pattern/mirror-registry-ca-cert.pem,
#  ~/.coco-pattern/mirror-registry-password) that don't exist on connected
# deployments.
#
# Usage:
#   ./scripts/enable-airgap-secrets.sh [path-to-values-secret-file]
#
# Idempotent: safe to run more than once against the same file.

set -euo pipefail

VALUES_FILE="${1:-${HOME}/values-secret-coco-pattern.yaml}"

if [ ! -f "${VALUES_FILE}" ]; then
	echo "ERROR: ${VALUES_FILE} not found." >&2
	echo "  Run 'make gen-secrets' first, or pass the path explicitly:" >&2
	echo "  $0 <path-to-values-secret-file>" >&2
	exit 1
fi

if ! grep -q "AIRGAP-MIRROR-SECRETS-START" "${VALUES_FILE}"; then
	echo "ERROR: ${VALUES_FILE} has no AIRGAP-MIRROR-SECRETS markers." >&2
	echo "  Was it generated from an older values-secret.yaml.template? Regenerate with 'make gen-secrets'." >&2
	exit 1
fi

sed -i.bak '
/# AIRGAP-MIRROR-SECRETS-START/,/# AIRGAP-MIRROR-SECRETS-END/ {
  /AIRGAP-MIRROR-SECRETS-START/b
  /AIRGAP-MIRROR-SECRETS-END/b
  s/^\([[:space:]]*\)#/\1/
}
' "${VALUES_FILE}"
rm -f "${VALUES_FILE}.bak"

echo "Uncommented airgap mirror secrets (registryCaCert, bootstrap_secrets) in ${VALUES_FILE}"
echo
echo "Make sure these exist before 'make load-secrets' / 'make load-bootstrap':"
echo "  ~/.coco-pattern/mirror-registry-ca-cert.pem   (make cache-registry-ca)"
echo "  ~/.coco-pattern/mirror-registry-password      (make gen-mirror-helm-secret)"
