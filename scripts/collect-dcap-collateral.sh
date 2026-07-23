#!/usr/bin/env bash
# Collect TDX DCAP verification collateral from Intel PCS using pcsclient.py fetch
#
# This script:
#   1. Validates required parameters (FMSPC, Intel PCS API key)
#   2. Runs pcsclient.py fetch to download TDX verification collateral
#   3. Produces platform_collaterals.json for loading into Vault via 'make load-secrets'
#
# The output JSON contains TCB info, QE identity, and PCK CRL data needed by
# the Trustee dcap_verifier in file:// mode. This is platform-level data that
# does NOT change per-cluster — only per CPU family (identified by FMSPC).
#
# Usage:
#   ./scripts/collect-dcap-collateral.sh --fmspc FMSPC --api-key KEY [OPTIONS]
#
# Options:
#   --fmspc FMSPC               Platform FMSPC hex string (REQUIRED, e.g. "00606A000000")
#   --api-key KEY               Intel PCS API key (REQUIRED, or set INTEL_PCS_API_KEY env var)
#   --pcsclient-dir PATH        Path to PcsClientTool directory
#                               (default: ~/confidential-computing.tee.dcap/tools/PcsClientTool)
#   -o, --output PATH           Override output directory (default: ~/.coco-pattern/dcap-offline)
#   -h, --help                  Show this help message
#
# Prerequisites:
#   git clone https://github.com/intel/confidential-computing.tee.dcap.git \
#       ~/confidential-computing.tee.dcap
#   pip install -r ~/confidential-computing.tee.dcap/tools/PcsClientTool/requirements.txt

set -euo pipefail

# Defaults
FMSPC=""
API_KEY="${INTEL_PCS_API_KEY:-}"
PCSCLIENT_DIR="${HOME}/confidential-computing.tee.dcap/tools/PcsClientTool"
OUTPUT_DIR="${HOME}/.coco-pattern/dcap-offline"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --fmspc)
            FMSPC="$2"
            shift 2
            ;;
        --api-key)
            API_KEY="$2"
            shift 2
            ;;
        --pcsclient-dir)
            PCSCLIENT_DIR="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,28p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            echo "Run with --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$FMSPC" ]; then
    echo "Error: --fmspc is required (e.g. --fmspc 00606A000000)" >&2
    echo "The FMSPC identifies your platform's CPU family for collateral lookup." >&2
    echo "Run with --help for usage information." >&2
    exit 1
fi

if [ -z "$API_KEY" ]; then
    echo "Error: Intel PCS API key is required." >&2
    echo "Provide via --api-key KEY or set INTEL_PCS_API_KEY environment variable." >&2
    echo "Get an API key from: https://api.portal.trustedservices.intel.com/" >&2
    exit 1
fi

# Check that pcsclient.py exists
PCSCLIENT_PY="${PCSCLIENT_DIR}/pcsclient.py"
if [ ! -f "$PCSCLIENT_PY" ]; then
    echo "Error: pcsclient.py not found at $PCSCLIENT_PY" >&2
    echo "" >&2
    echo "To install the Intel PCS Client Tool:" >&2
    echo "  git clone https://github.com/intel/confidential-computing.tee.dcap.git \\" >&2
    echo "      ~/confidential-computing.tee.dcap" >&2
    echo "  pip install -r ~/confidential-computing.tee.dcap/tools/PcsClientTool/requirements.txt" >&2
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

OUTPUT_FILE="${OUTPUT_DIR}/platform_collaterals.json"

echo "Collecting TDX DCAP verification collateral..."
echo "  FMSPC:      $FMSPC"
echo "  Tool:       $PCSCLIENT_PY"
echo "  Output:     $OUTPUT_FILE"
echo ""

# Run pcsclient.py fetch to collect collateral
# IMPORTANT: Use 'fetch' subcommand (produces JSON for Trustee dcap_verifier file:// mode)
# Do NOT use 'cache' (produces binary QPL cache files for QCNL library)
python3 "$PCSCLIENT_PY" fetch \
    --fmspc "$FMSPC" \
    --api_key "$API_KEY" \
    -o "$OUTPUT_FILE"

# Verify output file exists and is valid JSON
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "Error: pcsclient.py fetch did not produce output file: $OUTPUT_FILE" >&2
    exit 1
fi

if ! python3 -m json.tool < "$OUTPUT_FILE" > /dev/null 2>&1; then
    echo "Error: Output file is not valid JSON: $OUTPUT_FILE" >&2
    echo "This may indicate a pcsclient.py version mismatch or network error." >&2
    exit 1
fi

# Report success
FILE_SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
echo ""
echo "Success! Collateral collected."
echo "  File: $OUTPUT_FILE"
echo "  Size: $FILE_SIZE bytes"
echo ""
echo "Next step: Load into Vault via:"
echo "  make load-secrets"
echo ""
echo "Note: Collateral expires in ~30-90 days. Re-run this script to refresh."
