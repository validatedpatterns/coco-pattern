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
#   ./scripts/collect-dcap-collateral.sh [OPTIONS]
#
# Options:
#   --pcsclient-dir PATH        Path to PcsClientTool directory
#                               (default: ~/confidential-computing.tee.dcap/tools/PcsClientTool)
#   -o, --output PATH           Override output directory (default: ~/.coco-pattern/dcap-offline)
#   -h, --help                  Show this help message
#
# Prerequisites:
#   git clone https://github.com/intel/confidential-computing.tee.dcap.git \
#       ~/confidential-computing.tee.dcap
#   pip install -r ~/confidential-computing.tee.dcap/tools/PcsClientTool/requirements.txt
#
# The Intel PCS API key must be configured in the OS keyring. On first run,
# pcsclient.py will prompt for the key and optionally save it.

set -euo pipefail

# Defaults
PCSCLIENT_DIR="${HOME}/confidential-computing.tee.dcap/tools/PcsClientTool"
OUTPUT_DIR="${HOME}/.coco-pattern/dcap-offline"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --pcsclient-dir)
            PCSCLIENT_DIR="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            echo "Run with --help for usage information" >&2
            exit 1
            ;;
    esac
done

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
echo "  Tool:       $PCSCLIENT_PY"
echo "  Output:     $OUTPUT_FILE"
echo ""

# Run pcsclient.py fetch to collect collateral
# IMPORTANT: Use 'fetch' subcommand (produces JSON for Trustee dcap_verifier file:// mode)
# Do NOT use 'cache' (produces binary QPL cache files for QCNL library)
#
# pcsclient.py fetch retrieves all FMSPCs from Intel PCS and downloads
# TCB info, QE identity, and CRL data. The API key must be pre-configured
# in the OS keyring (pcsclient.py prompts interactively on first run).
# Use -t early for early TCB update type (matches kbs-config.toml).
python3 "$PCSCLIENT_PY" fetch \
    -o "$OUTPUT_FILE" \
    -t early \
    -p all

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
