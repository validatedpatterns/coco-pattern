#!/usr/bin/env bash
# Uncomments the airgap-only secrets in a generated values-secret file
# (registryCaCert, bootstrap_secrets, tdxCollateral) and comments OUT
# intelPcsApiKey (airgap manages PCK via scripts/dcap-pck.py). Rationale and
# file paths: values-secret.yaml.template. Usage: enable-airgap-secrets.sh [path]

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
/# AIRGAP-TDX-COLLATERAL-START/,/# AIRGAP-TDX-COLLATERAL-END/ {
  /AIRGAP-TDX-COLLATERAL-START/b
  /AIRGAP-TDX-COLLATERAL-END/b
  s/^\([[:space:]]*\)#/\1/
}
' "${VALUES_FILE}"
rm -f "${VALUES_FILE}.bak"

# Comment out intelPcsApiKey (connected-mode zero-touch registration only).
# In airgap mode PCK certificates are provisioned manually via
# scripts/dcap-pck.py; the connected key file must not be required.
sed -i.bak '
/^  - name: intelPcsApiKey$/,/^[[:space:]]*$/ {
  /^[[:space:]]*$/b
  s/^/#/
}
' "${VALUES_FILE}"
rm -f "${VALUES_FILE}.bak"

echo "Uncommented airgap mirror secrets (registryCaCert, bootstrap_secrets, tdxCollateral) in ${VALUES_FILE}"
echo "Commented out intelPcsApiKey (connected-mode zero-touch registration) in ${VALUES_FILE}"
echo
echo "Make sure these exist before 'make load-secrets' / 'make load-bootstrap':"
echo "  ~/.coco-pattern/mirror-registry-ca-cert.pem   (make cache-registry-ca)"
echo "  ~/.coco-pattern/mirror-registry-password      (make gen-mirror-helm-secret)"
echo "  ~/.coco-pattern/dcap-offline/platform_collaterals.json  (make collect-dcap-collateral)"
