#!/usr/bin/env bash
# Collect firmware reference values using veritas container (runs locally, no cluster pods)
#
# This script:
#   1. Runs veritas via podman container to compute firmware measurements
#   2. Extracts reference values from OCP release artifacts (baremetal) or
#      dm-verity image (azure)
#   3. Saves to ~/.coco-pattern/ for loading into Vault via 'make load-secrets'
#
# Usage:
#   ./scripts/collect-firmware-refvals.sh [OPTIONS]
#
# Options:
#   --platform <platform>    Platform: baremetal (default) or azure
#   -o, --output <path>      Override output path
#   -p, --pull-secret <path> Pull secret file (default: ~/pull-secret.json)
#   -v, --ocp-version <ver>  OCP version (baremetal; default: auto-detect)
#   --osc-version <ver>      OSC operator version (azure; default: auto-detect)
#   -t, --tee <tdx|snp>      TEE type (default: tdx)
#   -h, --help               Show this help message

set -euo pipefail

# Defaults
PLATFORM="baremetal"
OUTPUT_FILE=""
PULL_SECRET="${HOME}/pull-secret.json"
OCP_VERSION=""
OSC_VERSION=""
TEE="tdx"
CONTAINER_IMAGE="quay.io/openshift_sandboxed_containers/coco-tools:1.12"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
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
        --osc-version)
            OSC_VERSION="$2"
            shift 2
            ;;
        -t|--tee)
            TEE="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# //'
            exit 0
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            echo "Run with --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Validate platform
if [[ "$PLATFORM" != "baremetal" && "$PLATFORM" != "azure" ]]; then
    echo "Error: --platform must be 'baremetal' or 'azure'" >&2
    exit 1
fi

# Set default output file based on platform
if [ -z "$OUTPUT_FILE" ]; then
    if [ "$PLATFORM" = "azure" ]; then
        OUTPUT_FILE="${HOME}/.coco-pattern/measurements.json"
    else
        OUTPUT_FILE="${HOME}/.coco-pattern/firmware-reference-values.json"
    fi
fi

# Prerequisites check
command -v podman >/dev/null 2>&1 || { echo "Error: podman is required but not installed." >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "Error: yq is required but not installed." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed." >&2; exit 1; }

# Check pull secret exists
if [ ! -f "$PULL_SECRET" ]; then
    echo "Error: Pull secret not found at $PULL_SECRET" >&2
    echo "Provide path via --pull-secret or create ~/pull-secret.json" >&2
    exit 1
fi

# Build version args and resolve version for display
VERSION_ARGS=""
VERSION_DISPLAY=""
if [ "$PLATFORM" = "azure" ]; then
    if [ -z "$OSC_VERSION" ]; then
        # Auto-detect from the cluster's sandbox subscription CSV
        if command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
            echo "Detecting OSC version from cluster..."
            CSV=$(oc get subscription sandboxed-containers-operator \
                -n openshift-sandboxed-containers-operator \
                -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
            if [ -n "$CSV" ]; then
                OSC_VERSION="${CSV##*.v}"
                echo "Detected OSC version: $OSC_VERSION"
            fi
        fi
        if [ -z "$OSC_VERSION" ]; then
            echo "Could not auto-detect OSC version, using 'latest'" >&2
            OSC_VERSION="latest"
        fi
    fi
    VERSION_ARGS="--osc-version $OSC_VERSION"
    VERSION_DISPLAY="OSC $OSC_VERSION"
else
    if [ -z "$OCP_VERSION" ]; then
        if command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
            echo "Detecting OCP version from cluster..."
            OCP_VERSION=$(oc version -o json | yq -r '.openshiftVersion' 2>/dev/null || echo "")
        fi
        if [ -z "$OCP_VERSION" ]; then
            echo "Error: Could not auto-detect OCP version. Specify with --ocp-version" >&2
            exit 1
        fi
        echo "Detected OCP version: $OCP_VERSION"
    fi
    VERSION_ARGS="--ocp-version $OCP_VERSION"
    VERSION_DISPLAY="OCP $OCP_VERSION"
fi

echo "=========================================="
echo "Firmware Reference Value Collection"
echo "=========================================="
echo "Platform:       $PLATFORM"
echo "Version:        $VERSION_DISPLAY"
echo "TEE Type:       $TEE"
echo "Output file:    $OUTPUT_FILE"
echo ""

# Create temp directory for output
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Build veritas command
VERITAS_CMD="veritas --platform $PLATFORM --tee $TEE $VERSION_ARGS --authfile /pull-secret.json"

# Add baremetal-specific flags
if [ "$PLATFORM" = "baremetal" ]; then
    VERITAS_CMD="$VERITAS_CMD --hw-xfam-allow x87 --hw-xfam-allow sse --hw-xfam-allow avx"
fi

VERITAS_CMD="$VERITAS_CMD -o /output"

echo "Running veritas to compute firmware measurements..."
echo "(This may take 2-3 minutes to download and process artifacts)"
echo ""

podman run --rm \
    -v "${PULL_SECRET}:/pull-secret.json:ro,z" \
    -v "${TEMP_DIR}:/output:z" \
    "$CONTAINER_IMAGE" \
    $VERITAS_CMD

# Extract reference-values.json from ConfigMap and transform array -> object
echo ""
echo "Extracting reference values..."
# -r ensures the embedded JSON string is output raw (not quoted),
# which is required for yq v3 (kislyuk/yq) compatibility.
# yq v4 (mikefarah/yq) outputs raw scalars by default but -r is harmless.
yq -r '.data["reference-values.json"]' "$TEMP_DIR/rvps-reference-values.yaml" | \
  jq '[.[] | {(.name): .value}] | add' > "$OUTPUT_FILE"

# Save output
mkdir -p "$(dirname "$OUTPUT_FILE")"

echo ""
echo "Collected firmware reference values:"
jq . "$OUTPUT_FILE"
echo ""
echo "Saved to: $OUTPUT_FILE"
echo ""
if [ "$PLATFORM" = "azure" ]; then
    VAULT_KEY="pcrStash"
else
    VAULT_KEY="firmwareReferenceValues"
fi
echo "Next steps:"
echo "1. Review the collected values: cat $OUTPUT_FILE"
echo "2. Ensure '$VAULT_KEY' is configured in ~/values-secret-coco-pattern.yaml"
echo "3. Run: make load-secrets"
echo ""
