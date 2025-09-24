#!/usr/bin/env bash

echo "Creating secrets as required"
echo 

COCO_SECRETS_DIR="${HOME}/.coco-pattern"
SECURITY_POLICY_FILE="${COCO_SECRETS_DIR}/security-policy-config.json"
SSH_KEY_FILE="${COCO_SECRETS_DIR}/id_rsa"
KBS_PRIVATE_KEY="${COCO_SECRETS_DIR}/kbsPrivateKey"
KBS_PUBLIC_KEY="${COCO_SECRETS_DIR}/kbsPublicKey"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
VALUES_FILE="${HOME}/values-secret-coco-pattern.yaml"

mkdir -p ${COCO_SECRETS_DIR}

if [ ! -f "${SECURITY_POLICY_FILE}" ]; then
echo "Creating security policy"
cat > ${SECURITY_POLICY_FILE} <<EOF
{
  "default": [
  {
    "type": "insecureAcceptAnything"
  }],
  "transports": {}
}
EOF

fi

if [ ! -f "${KBS_PRIVATE_KEY}" ]; then
    echo "Creating kbs keys"
    rm -f "${KBS_PUBLIC_KEY}"
    openssl genpkey -algorithm ed25519 > ${KBS_PRIVATE_KEY}
    openssl pkey -in "${KBS_PRIVATE_KEY}" -pubout -out "${KBS_PUBLIC_KEY}"
fi

if [ ! -f "${SSH_KEY_FILE}" ]; then
    echo "Creating ssh keys"
    rm -f "${SSH_KEY_FILE}.pub"
    ssh-keygen -f "${SSH_KEY_FILE}" -N ""
fi


## Copy a sample values file if this stuff doesn't exist

if [ ! -f "${VALUES_FILE}" ]; then
    echo "No values file was found copying template.. please review before deploying"
    cp "${SCRIPT_DIR}/../values-secret.yaml.template" "${VALUES_FILE}"
fi


## Setup for baremetal
if [ ! -f "${COCO_SECRETS_DIR}/pccs_private.pem" ]; then
    openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -keyout ${COCO_SECRETS_DIR}/pccs_private.pem -out ${COCO_SECRETS_DIR}/pccs_certificate.pem -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=pccs-service.intel-dcap.svc.cluster.local"
fi


if [ ! -f "${COCO_SECRETS_DIR}/pccs_user_token" ]; then
    echo "Creating pccs user token"
    echo "usertoken" > ${COCO_SECRETS_DIR}/pccs_user_token
fi
# Always do the hash
echo "Hi"
echo $(which sha512sum)
echo ${COCO_SECRETS_DIR}/pccs_user_token_hash
PCCS_USER_TOKEN_HASH=$(echo -n "usertoken" | sha512sum | tr -d '[:space:]-')
echo -n "usertoken" | sha512sum | tr -d '[:space:]-' > ${COCO_SECRETS_DIR}/pccs_user_token_hash

if [ ! -f "${COCO_SECRETS_DIR}/pccs_admin_token" ]; then
    echo "Creating pccs admin token"
    echo "admintoken" > ${COCO_SECRETS_DIR}/pccs_admin_token
fi
# Always do the hash
echo -n "admintoken" | sha512sum | tr -d '[:space:]-' > ${COCO_SECRETS_DIR}/pccs_admin_token_hash