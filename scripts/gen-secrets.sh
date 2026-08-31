#!/usr/bin/env bash

echo "Creating secrets as required"
echo

COCO_SECRETS_DIR="${HOME}/.coco-pattern"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${HOME}/values-secret-coco-pattern.yaml"

mkdir -p ${COCO_SECRETS_DIR}

## Ensure both platform-specific reference-value files exist. The
## values-secret template enables pcrStash (Azure) and firmwareReferenceValues
## (bare metal) unconditionally so the same file works on either topology.
## This pre-touches an empty '{}' placeholder for whichever platform's file
## doesn't exist yet, so 'make load-secrets' won't fail with a missing-file
## error before collect-firmware-refvals.sh has been run for your platform.
## Real collected data (from collect-firmware-refvals.sh) always overwrites
## these placeholders.
for refval_file in measurements.json firmware-reference-values.json; do
	if [ ! -f "${COCO_SECRETS_DIR}/${refval_file}" ]; then
		echo '{}' >"${COCO_SECRETS_DIR}/${refval_file}"
	fi
done

SSH_KEY_FILE="${COCO_SECRETS_DIR}/id_rsa"

if [ "${COCO_ENABLE_SSH_DEBUG:-false}" = "true" ]; then
	if [ ! -f "${SSH_KEY_FILE}" ]; then
		echo "Creating ssh keys for podvm debug access"
		rm -f "${SSH_KEY_FILE}.pub"
		ssh-keygen -f "${SSH_KEY_FILE}" -N ""
	fi
fi

## JWK signing key for sealed secrets (P-256 EC key)
JWK_SIGNING_KEY="${COCO_SECRETS_DIR}/sealed-secrets-signing.jwk"
JWK_PUBLIC_KEY="${COCO_SECRETS_DIR}/sealed-secrets-signing-pub.jwk"

if [ ! -f "${JWK_SIGNING_KEY}" ]; then
	if command -v jose >/dev/null 2>&1; then
		echo "Creating sealed secrets JWK signing key (P-256 EC) using jose"
		jose jwk gen -i '{"alg":"ES256","kid":"coco-signing-key","use":"sig"}' -o "${JWK_SIGNING_KEY}"
		jose jwk pub -i "${JWK_SIGNING_KEY}" -o "${JWK_PUBLIC_KEY}"
	else
		echo "ERROR: jose CLI not found. Install with: sudo dnf install jose"
		echo "The jose package is available in rhel-10-for-x86_64-appstream-rpms"
		exit 1
	fi
fi

## Copy a sample values file if this stuff doesn't exist

if [ ! -f "${VALUES_FILE}" ]; then
	echo
	echo "========================================================================"
	echo "IMPORTANT: Created values-secret file at ${VALUES_FILE}"
	echo "========================================================================"
	echo
	cp "${SCRIPT_DIR}/../values-secret.yaml.template" "${VALUES_FILE}"
	echo "ACTION REQUIRED: Review and customize this file before deploying:"
	echo
	echo "  For Azure deployments:"
	echo "    - Run 'make collect-azure-refvals' to collect PCR measurements"
	echo "    - pcrStash is already enabled by default; no need to uncomment anything"
	echo "    - SSH debug is optional (uncomment sshKey if needed)"
	echo "    - DCAP collateral (tdxCollateral) is bare-metal-TDX-only; leave commented out"
	echo
	echo "  For Bare Metal deployments:"
	echo "    - Run 'make collect-firmware-refvals' to collect firmware measurements"
	echo "    - firmwareReferenceValues is already enabled by default; no need to uncomment anything"
	echo "    - For Intel TDX: run 'make collect-dcap-collateral', then uncomment tdxCollateral"
	echo "      in the values-secret file for offline attestation"
	echo "    - SSH debug is optional (uncomment sshKey if needed)"
	echo "    - See docs/firmware-reference-values.md for reference value collection"
	echo
	echo "  For airgap (disconnected) deployments:"
	echo "    - registryCaCert and bootstrap_secrets (mirror-registry-helm-oci) are"
	echo "      commented out by default -- run 'make cache-registry-ca' and"
	echo "      'make gen-mirror-helm-secret', then 'make enable-airgap-secrets' to"
	echo "      uncomment both blocks in the generated values-secret file"
	echo "    - See airgap/DEPLOY-RUNBOOK.md for the full deployment procedure"
	echo
	echo "  Security policies:"
	echo "    - Default is 'insecure' (accepts all images)"
	echo "    - For production, configure 'signed' policy with cosign keys"
	echo
	echo "File location: ${VALUES_FILE}"
	echo "========================================================================"
	echo
fi
