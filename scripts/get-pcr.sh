#!/usr/bin/env bash
set -e

# Script to retrieve the sandboxed container operator CSV for the current clusterGroup
# using the pull secret for authentication if needed.

# 1. Locate pull secret
PULL_SECRET_PATH="${HOME}/pull-secret.json"
if [ ! -f "$PULL_SECRET_PATH" ]; then
    if [ -n "${PULL_SECRET}" ]; then
        PULL_SECRET_PATH="${PULL_SECRET}"
        if [ ! -f "$PULL_SECRET_PATH" ]; then
            echo "ERROR: Pull secret file not found at path specified in PULL_SECRET: $PULL_SECRET_PATH"
            exit 1
        fi
    else
        echo "ERROR: Pull secret not found at ~/pull-secret.json"
        echo "Please either place your pull secret at ~/pull-secret.json or set the PULL_SECRET environment variable"
        exit 1
    fi
fi

echo "Using pull secret: $PULL_SECRET_PATH"

# 2. Check for required tools
if ! command -v yq &> /dev/null; then
    echo "ERROR: yq is required but not installed"
    echo "Please install yq: https://github.com/mikefarah/yq#install"
    exit 1
fi

if ! command -v skopeo &> /dev/null; then
    echo "ERROR: skopeo is required but not installed"
    echo "Please install skopeo: https://github.com/containers/skopeo/blob/main/install.md"
    exit 1
fi

if ! command -v podman &> /dev/null; then
    echo "ERROR: podman is required but not installed"
    echo "Please install podman: https://podman.io/docs/installation"
    exit 1
fi

# 3. Check values-global.yaml exists
if [ ! -f "values-global.yaml" ]; then
    echo "ERROR: values-global.yaml not found in current directory"
    echo "Please run this script from the root directory of the project"
    exit 1
fi

# 4. Get the active clusterGroupName from values-global.yaml
CLUSTER_GROUP_NAME=$(yq eval '.main.clusterGroupName' values-global.yaml)

if [ -z "$CLUSTER_GROUP_NAME" ] || [ "$CLUSTER_GROUP_NAME" == "null" ]; then
    echo "ERROR: Could not determine clusterGroupName from values-global.yaml"
    echo "Expected: main.clusterGroupName to be set"
    exit 1
fi

echo "Active clusterGroup: $CLUSTER_GROUP_NAME"

# 5. Locate the values file for the active clusterGroup
VALUES_FILE="values-${CLUSTER_GROUP_NAME}.yaml"

if [ ! -f "$VALUES_FILE" ]; then
    echo "ERROR: Values file for clusterGroup not found: $VALUES_FILE"
    exit 1
fi

# 6. Get the sandboxed container operator CSV from the clusterGroup values
SANDBOX_CSV=$(yq eval '.clusterGroup.subscriptions.sandbox.csv' "$VALUES_FILE")

if [ -z "$SANDBOX_CSV" ] || [ "$SANDBOX_CSV" == "null" ]; then
    echo "WARNING: No sandboxed container operator CSV found in $VALUES_FILE"
    echo "The subscription clusterGroup.subscriptions.sandbox.csv is not defined"
    exit 0
fi

# Extract version from CSV (e.g., "sandboxed-containers-operator.v1.12.0" -> "1.12.0")
# Remove everything up to and including ".v"
SANDBOX_VERSION="${SANDBOX_CSV##*.v}"

echo "Sandboxed container operator CSV: $SANDBOX_CSV"
echo "Version: $SANDBOX_VERSION"
# alternatively, use the operator-version tag.
# OSC_VERSION=1.12.0
VERITY_IMAGE=registry.redhat.io/openshift-sandboxed-containers/osc-dm-verity-image

TAG=$(skopeo inspect --authfile $PULL_SECRET_PATH docker://${VERITY_IMAGE}:${SANDBOX_VERSION} | jq -r .Digest)

IMAGE=${VERITY_IMAGE}@${TAG}

echo "IMAGE: $IMAGE"

curl -L https://tuf-default.apps.rosa.rekor-prod.2jng.p3.openshiftapps.com/targets/rekor.pub -o rekor.pub
curl -L https://security.access.redhat.com/data/63405576.txt -o cosign-pub-key.pem
# export REGISTRY_AUTH_FILE=${PULL_SECRET_PATH}
# echo "REGISTRY_AUTH_FILE: $REGISTRY_AUTH_FILE"
# export SIGSTORE_REKOR_PUBLIC_KEY=${PWD}/rekor.pub
# echo "SIGSTORE_REKOR_PUBLIC_KEY: $SIGSTORE_REKOR_PUBLIC_KEY"
# cosign verify --key cosign-pub-key.pem --output json  --rekor-url=https://rekor-server-default.apps.rosa.rekor-prod.2jng.p3.openshiftapps.com $IMAGE > cosign_verify.log


# Ensure output directory exists
mkdir -p ~/.coco-pattern

# Clean up any existing measurement files
rm -f ~/.coco-pattern/measurements-raw.json ~/.coco-pattern/measurements.json

# Download the measurements using podman cp (works on macOS with remote podman)
podman pull --authfile $PULL_SECRET_PATH $IMAGE

cid=$(podman create --entrypoint /bin/true $IMAGE)
echo "CID: ${cid}"
podman cp $cid:/image/measurements.json ~/.coco-pattern/measurements-raw.json
podman rm $cid

# Trim leading "0x" from all measurement values
jq 'walk(if type == "string" and startswith("0x") then .[2:] else . end)' \
    ~/.coco-pattern/measurements-raw.json > ~/.coco-pattern/measurements.json

echo "Measurements saved to ~/.coco-pattern/measurements.json (0x prefixes removed)"