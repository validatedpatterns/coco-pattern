#!/usr/bin/env bash
# Collect firmware reference values from a bare metal confidential VM
#
# This script automates the full lifecycle:
#   1. Launch a kata pod with the specified RuntimeClass
#   2. Install veritas inside the pod
#   3. Collect firmware measurements (TDX/SNP)
#   4. Copy output locally and transform to RVPS format
#   5. Save to ~/.coco-pattern/firmware-reference-values.json
#   6. Clean up the pod
#
# Usage:
#   ./scripts/collect-firmware-refvals.sh [OPTIONS]
#
# Options:
#   -m, --merge              Merge with existing file instead of overwriting
#   -n, --namespace <ns>     Namespace for collection pod (default: default)
#   -o, --output <path>      Override output path (default: ~/.coco-pattern/firmware-reference-values.json)
#   -r, --runtime-class <class>  Override RuntimeClass (default: kata-cc)
#   -i, --pod-image <image>  Override pod base image (default: registry.access.redhat.com/ubi9/ubi:latest)
#   -h, --help               Show this help message

set -euo pipefail

# Defaults
NAMESPACE="default"
OUTPUT_FILE="${HOME}/.coco-pattern/firmware-reference-values.json"
RUNTIME_CLASS="kata-cc"
POD_IMAGE="registry.access.redhat.com/ubi9/ubi:latest"
MERGE_MODE=false
POD_NAME="firmware-collector-$(date +%s)"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--merge)
            MERGE_MODE=true
            shift
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -r|--runtime-class)
            RUNTIME_CLASS="$2"
            shift 2
            ;;
        -i|--pod-image)
            POD_IMAGE="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,17p' "$0" | sed 's/^# //'
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
command -v oc >/dev/null 2>&1 || { echo "Error: oc CLI is required but not installed." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed." >&2; exit 1; }

# Check oc login
if ! oc whoami >/dev/null 2>&1; then
    echo "Error: Not logged in to OpenShift. Run 'oc login' first." >&2
    exit 1
fi

echo "=========================================="
echo "Firmware Reference Value Collection"
echo "=========================================="
echo "Namespace:      $NAMESPACE"
echo "RuntimeClass:   $RUNTIME_CLASS"
echo "Pod image:      $POD_IMAGE"
echo "Output file:    $OUTPUT_FILE"
echo "Merge mode:     $MERGE_MODE"
echo ""

# Cleanup function (called via trap)
cleanup() {
    local exit_code=$?
    echo ""
    if [[ $exit_code -ne 0 ]]; then
        echo "⚠ Collection failed or was interrupted"
    fi

    if oc get pod "$POD_NAME" -n "$NAMESPACE" &>/dev/null; then
        echo "Cleaning up pod $POD_NAME..."
        oc delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found=true
    fi

    exit $exit_code
}

# Register cleanup on exit, error, or interrupt
trap cleanup EXIT ERR SIGINT SIGTERM

# Check for existing pod with same name and clean it up
if oc get pod "$POD_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "Found existing pod $POD_NAME, cleaning up..."
    oc delete pod "$POD_NAME" -n "$NAMESPACE" --wait=false
    sleep 2
fi

# Create kata pod
echo "Creating kata pod with RuntimeClass $RUNTIME_CLASS..."
cat <<EOF | oc apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
spec:
  runtimeClassName: $RUNTIME_CLASS
  restartPolicy: Never
  containers:
  - name: collector
    image: $POD_IMAGE
    command: ["sleep", "3600"]
    securityContext:
      privileged: false
EOF

# Wait for pod to be Ready
echo "Waiting for pod to be Ready..."
if ! oc wait --for=condition=Ready pod/$POD_NAME -n $NAMESPACE --timeout=120s; then
    echo "Error: Pod failed to become Ready within 120 seconds" >&2
    oc describe pod/$POD_NAME -n $NAMESPACE >&2
    exit 1
fi

echo "Pod is Ready"

# Install pip and veritas
echo "Installing pip and veritas inside pod..."
oc exec $POD_NAME -n $NAMESPACE -- bash -c "dnf install -y python3-pip > /dev/null 2>&1" || {
    echo "Error: Failed to install pip" >&2
    exit 1
}

oc exec $POD_NAME -n $NAMESPACE -- bash -c "pip install --quiet veritas-collectd" || {
    echo "Error: Failed to install veritas" >&2
    exit 1
}

# Run veritas collection
echo "Running veritas collection (this may take 30-60 seconds)..."
if ! oc exec $POD_NAME -n $NAMESPACE -- veritas collect --output /tmp/refvals.json; then
    echo "Error: Veritas collection failed" >&2
    echo "Check that the pod is running on hardware with TDX or SNP support" >&2
    exit 1
fi

# Copy output locally
echo "Copying veritas output locally..."
TEMP_RAW="/tmp/refvals-raw-$$.json"
oc cp $NAMESPACE/$POD_NAME:/tmp/refvals.json $TEMP_RAW || {
    echo "Error: Failed to copy veritas output from pod" >&2
    exit 1
}

# Transform to RVPS format
echo "Transforming to RVPS format..."
TEMP_RVPS="/tmp/refvals-rvps-$$.json"

jq -n \
    --arg mr_td "$(jq -r '.tdx.mr_td // empty' "$TEMP_RAW" 2>/dev/null || echo "")" \
    --arg rtmr_1 "$(jq -r '.tdx.rtmr[1] // empty' "$TEMP_RAW" 2>/dev/null || echo "")" \
    --arg rtmr_2 "$(jq -r '.tdx.rtmr[2] // empty' "$TEMP_RAW" 2>/dev/null || echo "")" \
    --arg xfam "$(jq -r '.tdx.xfam // empty' "$TEMP_RAW" 2>/dev/null || echo "")" \
    --arg snp_launch "$(jq -r '.snp.launch_measurement // empty' "$TEMP_RAW" 2>/dev/null || echo "")" \
    '{
        mr_td: (if $mr_td != "" then [$mr_td] else [] end),
        rtmr_1: (if $rtmr_1 != "" then [$rtmr_1] else [] end),
        rtmr_2: (if $rtmr_2 != "" then [$rtmr_2] else [] end),
        xfam: (if $xfam != "" then [$xfam] else [] end),
        snp_launch_measurement: (if $snp_launch != "" then [$snp_launch] else [] end)
    }' > "$TEMP_RVPS"

# Check if any values were extracted
VALUE_COUNT=$(jq '[.[] | select(length > 0)] | length' "$TEMP_RVPS")
if [ "$VALUE_COUNT" -eq 0 ]; then
    echo "Error: No firmware measurements found in veritas output" >&2
    echo "Veritas may not support this hardware or the output format changed" >&2
    rm -f "$TEMP_RAW" "$TEMP_RVPS"
    exit 1
fi

echo "Extracted firmware values:"
jq . "$TEMP_RVPS"

# Merge with existing file if requested
if [ "$MERGE_MODE" = true ] && [ -f "$OUTPUT_FILE" ]; then
    echo "Merging with existing file..."
    EXISTING_DATA=$(cat "$OUTPUT_FILE")

    MERGED_DATA=$(jq -n \
        --argjson existing "$EXISTING_DATA" \
        --argjson new "$(cat "$TEMP_RVPS")" \
        '$existing * $new |
         to_entries |
         map({
             key: .key,
             value: (.value | if type == "array" then (. + ($new[.key] // [])) | unique else . end)
         }) |
         from_entries'
    )

    echo "Merged firmware values:"
    echo "$MERGED_DATA" | jq .
    echo "$MERGED_DATA" > "$TEMP_RVPS"
fi

# Save to output file
mkdir -p "$(dirname "$OUTPUT_FILE")"
cp "$TEMP_RVPS" "$OUTPUT_FILE"

# Cleanup temp files
rm -f "$TEMP_RAW" "$TEMP_RVPS"

echo ""
echo "✓ Successfully collected firmware reference values"
echo ""
echo "Saved to: $OUTPUT_FILE"
echo ""
echo "Next steps:"
echo "1. Review the collected values: cat $OUTPUT_FILE"
echo "2. For bare metal deployments:"
echo "   - Uncomment 'firmwareReferenceValues' in ~/values-secret-coco-pattern.yaml"
echo "   - Run: make load-secrets"
echo "3. Verify the secret was synced to Vault:"
echo "   vault kv get secret/hub/firmwareReferenceValues"
echo "4. Force ExternalSecret sync on the KBS cluster (if needed):"
echo "   oc delete externalsecret firmware-refvals-eso -n trustee-operator-system"
echo ""
