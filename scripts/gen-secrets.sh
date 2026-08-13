#!/usr/bin/env bash

echo "Creating secrets as required"
echo

COCO_SECRETS_DIR="${HOME}/.coco-pattern"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${HOME}/values-secret-coco-pattern.yaml"

mkdir -p ${COCO_SECRETS_DIR}

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
	echo "    - SSH debug is optional (uncomment sshKey if needed)"
	echo "    - PCCS secrets can remain commented out"
	echo
	echo "  For Bare Metal deployments:"
	echo "    - Uncomment the PCCS secrets section"
	echo "    - Add your Intel PCS API key (get from https://api.portal.trustedservices.intel.com/)"
	echo "    - Run 'make collect-firmware-refvals' to collect firmware measurements"
	echo "    - Uncomment firmwareReferenceValues in values-secret file"
	echo "    - SSH debug is optional (uncomment sshKey if needed)"
	echo "    - See docs/pcr-reference-values-bare-metal.md for PCR collection"
	echo
	echo "  Security policies:"
	echo "    - Default is 'insecure' (accepts all images)"
	echo "    - For production, configure 'signed' policy with cosign keys"
	echo
	echo "File location: ${VALUES_FILE}"
	echo "========================================================================"
	echo
fi
