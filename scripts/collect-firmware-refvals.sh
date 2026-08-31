#!/usr/bin/env bash
# Collect firmware reference values using the veritas CLI (runs locally, no cluster pods)
#
# This script:
#   1. Runs veritas (installed on the host) to compute firmware measurements
#   2. Extracts reference values from OCP release artifacts (baremetal) or
#      dm-verity image (azure)
#   3. By default collects for BOTH TDX and SNP and merges the results, so a
#      single output supports heterogeneous (mixed-TEE) deployments
#   4. Saves to ~/.coco-pattern/ for loading into Vault via 'make load-secrets'
#
# veritas is installed on the host via pip (see Prerequisites below) rather
# than run in a container. The container image this script used to run
# (quay.io/openshift_sandboxed_containers/coco-tools) is pinned to an older
# veritas release that lacks --skip-tlog, which is needed to avoid repeated
# failures against Red Hat's private Rekor instance for Azure image signature
# verification. See the tracking issue for moving back to the container once
# a coco-tools release ships with a newer veritas.
#
# Prerequisites:
#   pip install "osc-veritas[snp]==0.1.3rc1"
#   cosign >= 2.0 (Azure only; https://docs.sigstore.dev/cosign/system_config/installation/)
#   tdx-measure (baremetal TDX only; cargo install --git https://github.com/virtee/tdx-measure tdx-measure-cli)
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
#   -t, --tee <tdx|snp|both> TEE type (default: both -- collects and merges both)
#   --verify-tlog            Azure only: verify against the Rekor transparency
#                            log instead of the default --skip-tlog. Only the
#                            signature check is skipped by default, not
#                            overall image verification.
#   -h, --help               Show this help message

set -euo pipefail

# Defaults
PLATFORM="baremetal"
OUTPUT_FILE=""
PULL_SECRET="${HOME}/pull-secret.json"
OCP_VERSION=""
OSC_VERSION=""
TEE="both"
SKIP_TLOG=true
VERITAS_PIP_SPEC='osc-veritas[snp]==0.1.3rc1'

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
        --verify-tlog)
            SKIP_TLOG=false
            shift
            ;;
        -h|--help)
            sed -n '2,39p' "$0" | sed 's/^# \?//'
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

# Validate TEE
case "$TEE" in
    tdx|snp|both) ;;
    *)
        echo "Error: --tee must be 'tdx', 'snp', or 'both'" >&2
        exit 1
        ;;
esac

# Set default output file based on platform
if [ -z "$OUTPUT_FILE" ]; then
    if [ "$PLATFORM" = "azure" ]; then
        OUTPUT_FILE="${HOME}/.coco-pattern/measurements.json"
    else
        OUTPUT_FILE="${HOME}/.coco-pattern/firmware-reference-values.json"
    fi
fi

# Prerequisites check
if ! command -v veritas >/dev/null 2>&1; then
    echo "Error: veritas is required but not installed." >&2
    echo "  Install with: pip install \"${VERITAS_PIP_SPEC}\"" >&2
    exit 1
fi
python3 -c "import yaml" 2>/dev/null || { echo "Error: python3 with PyYAML module is required. Install with: pip3 install pyyaml" >&2; exit 1; }

# cosign is only used by veritas for Azure image signature verification.
# Bare metal verifies via 'oc adm release info --verify' instead.
if [ "$PLATFORM" = "azure" ]; then
    if ! command -v cosign >/dev/null 2>&1; then
        echo "Error: cosign is required for Azure signature verification but was not found." >&2
        echo "  Install cosign >= 2.0: https://docs.sigstore.dev/cosign/system_config/installation/" >&2
        exit 1
    fi
    COSIGN_RAW_VERSION=$(cosign version 2>/dev/null | grep -oE 'GitVersion:[[:space:]]*v?[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [ -z "$COSIGN_RAW_VERSION" ]; then
        echo "WARNING: could not determine cosign version; veritas requires cosign >= 2.0" >&2
    else
        COSIGN_MAJOR="${COSIGN_RAW_VERSION%%.*}"
        if [ "$COSIGN_MAJOR" -lt 2 ]; then
            echo "Error: cosign >= 2.0 is required (found: $COSIGN_RAW_VERSION)" >&2
            exit 1
        fi
    fi
fi

# Check pull secret exists
if [ ! -f "$PULL_SECRET" ]; then
    echo "Error: Pull secret not found at $PULL_SECRET" >&2
    echo "Provide path via --pull-secret or create ~/pull-secret.json" >&2
    exit 1
fi

# Build version args and resolve version for display
VERSION_ARG_NAME=""
VERSION_ARG_VALUE=""
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
    VERSION_ARG_NAME="--image-tag"
    VERSION_ARG_VALUE="$OSC_VERSION"
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
    VERSION_ARG_NAME="--ocp-version"
    VERSION_ARG_VALUE="$OCP_VERSION"
    VERSION_DISPLAY="OCP $OCP_VERSION"
fi

if [ "$TEE" = "both" ]; then
    TEES_TO_RUN=(tdx snp)
else
    TEES_TO_RUN=("$TEE")
fi

echo "=========================================="
echo "Firmware Reference Value Collection"
echo "=========================================="
echo "Platform:       $PLATFORM"
echo "Version:        $VERSION_DISPLAY"
echo "TEE Type(s):    ${TEES_TO_RUN[*]}"
echo "Output file:    $OUTPUT_FILE"
echo ""

# Create temp directory for per-TEE veritas output and extracted JSON
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

extract_reference_values() {
    # Extract reference values from a veritas-produced ConfigMap YAML into a
    # plain JSON dict (supports both old and new veritas RVPS formats).
    local yaml_path="$1"
    python3 -c "
import yaml, json, base64, sys

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

data = doc.get('data', {})
result = {}

if 'reference_value' in data:
    # New format (veritas 0.1.x / Trustee 1.2): JSON object with base64-encoded RVPS entries
    raw = data['reference_value']
    entries = json.loads(raw) if isinstance(raw, str) else raw
    for claim_name, b64_value in entries.items():
        padded = b64_value + '=' * (-len(b64_value) % 4)
        decoded = json.loads(base64.urlsafe_b64decode(padded))
        result[claim_name] = decoded.get('value', decoded)
elif 'reference-values.json' in data:
    # Old format: JSON array of {name, hash-value} entries
    raw = data['reference-values.json']
    entries = json.loads(raw) if isinstance(raw, str) else raw
    for entry in entries:
        name = entry.get('name', '')
        value = entry.get('value', entry.get('hash-value', []))
        result[name] = value
else:
    print('Error: ConfigMap has neither reference_value nor reference-values.json key', file=sys.stderr)
    sys.exit(1)

print(json.dumps(result, indent=2))
" "$yaml_path"
}

PER_TEE_JSON_FILES=()

for tee in "${TEES_TO_RUN[@]}"; do
    OUT_DIR="${TEMP_DIR}/${tee}"
    mkdir -p "$OUT_DIR"

    VERITAS_ARGS=(--platform "$PLATFORM" --tee "$tee" "$VERSION_ARG_NAME" "$VERSION_ARG_VALUE" --authfile "$PULL_SECRET")

    # XFAM CPU features only matter for TDX; only add for the tdx run to
    # avoid veritas's harmless-but-noisy "only relevant for TDX" warning.
    if [ "$PLATFORM" = "baremetal" ] && [ "$tee" = "tdx" ]; then
        VERITAS_ARGS+=(--hw-xfam-allow x87 --hw-xfam-allow sse --hw-xfam-allow avx)
    fi

    # cosign/Rekor verification only applies to the Azure branch. Default to
    # --skip-tlog: Red Hat signs and logs these images against its own
    # private Rekor instance, which has been unreliable. --skip-tlog still
    # verifies the cosign signature against Red Hat's public key -- it only
    # skips the transparency-log lookup, which cannot succeed against a
    # different Rekor server anyway (the log entry only exists on Red Hat's
    # instance). Pass --verify-tlog to opt back into full verification.
    if [ "$PLATFORM" = "azure" ] && [ "$SKIP_TLOG" = true ]; then
        VERITAS_ARGS+=(--skip-tlog)
    fi

    VERITAS_ARGS+=(-o "$OUT_DIR")

    echo "Running veritas (tee=$tee)..."
    echo "(This may take 2-3 minutes to download and process artifacts)"
    veritas "${VERITAS_ARGS[@]}"
    echo ""

    TEE_JSON="${TEMP_DIR}/${tee}.json"
    extract_reference_values "${OUT_DIR}/rvps-reference-values.yaml" > "$TEE_JSON"
    PER_TEE_JSON_FILES+=("$TEE_JSON")
done

echo "Merging reference values from: ${TEES_TO_RUN[*]}..."
mkdir -p "$(dirname "$OUTPUT_FILE")"

python3 -c "
import json, sys

result = {}
for path in sys.argv[1:]:
    with open(path) as f:
        data = json.load(f)
    for key, value in data.items():
        if key in result and result[key] != value:
            print(f\"WARNING: key '{key}' differs between TEE runs; keeping the first value seen\", file=sys.stderr)
            continue
        result[key] = value

print(json.dumps(result, indent=2))
" "${PER_TEE_JSON_FILES[@]}" > "$OUTPUT_FILE"

echo ""
echo "Collected firmware reference values:"
python3 -m json.tool "$OUTPUT_FILE"
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
