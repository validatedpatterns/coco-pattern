#!/usr/bin/env bash
# Collect firmware reference values using veritas container (runs locally, no cluster pods)
#
# This script:
#   1. Runs veritas via podman container to compute firmware measurements
#   2. Extracts reference values from OCP release artifacts
#   3. Saves to ~/.coco-pattern/firmware-reference-values.json
#   4. values-secret.yaml.template loads to Vault via 'make load-secrets'
#
# Usage:
#   ./scripts/collect-firmware-refvals.sh [OPTIONS]
#
# Options:
#   -o, --output <path>      Override output path (default: ~/.coco-pattern/firmware-reference-values.json)
#   -p, --pull-secret <path> Pull secret file (default: ~/pull-secret.json)
#   -v, --ocp-version <ver>  OCP version (default: auto-detect from cluster)
#   -t, --tee <tdx|snp>      TEE type (default: tdx)
#   -h, --help               Show this help message

set -euo pipefail

# Defaults
OUTPUT_FILE="${HOME}/.coco-pattern/firmware-reference-values.json"
PULL_SECRET="${HOME}/pull-secret.json"
OCP_VERSION=""
TEE="tdx"
CONTAINER_IMAGE="quay.io/openshift_sandboxed_containers/coco-tools:1.12"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -p|--pull-secret)
            PULL_SECRET="$2"
            shift 2
            ;;
        -v|--ocp-version)
            OCP_VERSION="$2"
            shift 2
            ;;
        -t|--tee)
            TEE="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,14p' "$0" | sed 's/^# //'
            exit 0
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            echo "Run with --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Prerequisites check
command -v podman >/dev/null 2>&1 || { echo "Error: podman is required but not installed." >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "Error: yq is required but not installed." >&2; exit 1; }

# Check pull secret exists
if [ ! -f "$PULL_SECRET" ]; then
    echo "Error: Pull secret not found at $PULL_SECRET" >&2
    echo "Provide path via --pull-secret or create ~/pull-secret.json" >&2
    exit 1
fi

# Auto-detect OCP version if not specified
if [ -z "$OCP_VERSION" ]; then
    if command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
        echo "Detecting OCP version from cluster..."
        OCP_VERSION=$(oc version -o json | yq -r '.openshiftVersion' 2>/dev/null || echo "")
        if [ -z "$OCP_VERSION" ]; then
            echo "Error: Could not auto-detect OCP version. Specify with --ocp-version" >&2
            exit 1
        fi
        echo "Detected OCP version: $OCP_VERSION"
    else
        echo "Error: Not logged in to cluster and no --ocp-version specified" >&2
        exit 1
    fi
fi

echo "=========================================="
echo "Firmware Reference Value Collection"
echo "=========================================="
echo "OCP Version:    $OCP_VERSION"
echo "TEE Type:       $TEE"
echo "Output file:    $OUTPUT_FILE"
echo ""

# Create temp directory for output
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Run veritas via podman
echo "Running veritas to compute firmware measurements..."
echo "(This may take 2-3 minutes to download and process OCP release artifacts)"
echo ""

podman run --rm \
    -v "${PULL_SECRET}:/pull-secret.json:ro,z" \
    -v "${TEMP_DIR}:/output:z" \
    "$CONTAINER_IMAGE" \
    veritas --platform baremetal --tee "$TEE" \
    --ocp-version "$OCP_VERSION" \
    --authfile /pull-secret.json \
    --hw-xfam-allow x87 --hw-xfam-allow sse --hw-xfam-allow avx \
    -o /output

# Extract reference-values.json from ConfigMap
echo ""
echo "Extracting reference values..."
yq '.data["reference-values.json"]' "$TEMP_DIR/rvps-reference-values.yaml" > "$OUTPUT_FILE"

echo ""
echo "✓ Successfully collected firmware reference values"
echo ""
echo "Saved to: $OUTPUT_FILE"
echo ""
echo "Next steps:"
echo "1. Review the collected values: cat $OUTPUT_FILE"
echo "2. Uncomment 'firmwareReferenceValues' in ~/values-secret-coco-pattern.yaml"
echo "3. Run: make load-secrets"
echo "4. Verify upload: vault kv get secret/hub/firmwareReferenceValues"
echo ""
