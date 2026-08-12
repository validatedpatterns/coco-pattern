#!/usr/bin/env bash
# Collect TDX DCAP verification collateral from Intel PCS using pcsclient.py fetch
#
# This script:
#   1. Runs pcsclient.py fetch -p E5 to download TDX collateral (no API key needed)
#   2. Applies a jq fixup to convert string-encoded QE identity fields to JSON structs
#   3. Produces platform_collaterals.json for loading into Vault via 'make load-secrets'
#
# The output JSON contains TCB info, QE identity, and PCK CRL data needed by
# the Trustee dcap_verifier in file:// mode. This is platform-level data that
# does NOT change per-cluster — only per CPU family (identified by FMSPC).
#
# IMPORTANT: Run AFTER pcsclient.py cache (E-3). The cache step provisions PCK
# certs for the specific platform. This fetch step gets the verification collateral
# (QeIdentity, TcbInfo, CRLs) needed by KBS to verify attestation reports.
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
#   jq installed (used for QE identity fixup)
#
# No Intel PCS API key is required — fetch without -i uses public endpoints.

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

# Check prerequisites
PCSCLIENT_PY="${PCSCLIENT_DIR}/pcsclient.py"
if [ ! -f "$PCSCLIENT_PY" ]; then
    echo "Error: pcsclient.py not found at $PCSCLIENT_PY" >&2
    echo "  git clone https://github.com/intel/confidential-computing.tee.dcap.git \\" >&2
    echo "      ~/confidential-computing.tee.dcap" >&2
    echo "  pip install -r ~/confidential-computing.tee.dcap/tools/PcsClientTool/requirements.txt" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for QE identity fixup but was not found" >&2
    echo "  Install: sudo dnf install jq" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

RAW_FILE="${OUTPUT_DIR}/platform_collateral_fix.json"
OUTPUT_FILE="${OUTPUT_DIR}/platform_collaterals.json"

echo "Collecting TDX DCAP verification collateral..."
echo "  Tool:       $PCSCLIENT_PY"
echo "  Raw output: $RAW_FILE"
echo "  Final:      $OUTPUT_FILE"
echo ""

# Step 1: Fetch collateral from Intel PCS.
# -p E5  — TDX E5 platform type (required for TDX QeIdentity; 'all' omits it)
# -t early — early TCB update type (matches kbs-config.toml)
# No -i platform_list.json and no API key needed — public endpoints only.
# Remove raw file first so pcsclient.py does not prompt "Overwrite? (y/n)" interactively.
rm -f "$RAW_FILE"
python3 "$PCSCLIENT_PY" fetch \
    -p E5 \
    -t early \
    -o "$RAW_FILE"

if [ ! -f "$RAW_FILE" ]; then
    echo "Error: pcsclient.py fetch did not produce $RAW_FILE" >&2
    exit 1
fi

if ! python3 -m json.tool < "$RAW_FILE" > /dev/null 2>&1; then
    echo "Error: $RAW_FILE is not valid JSON" >&2
    exit 1
fi

# Step 2: Apply jq fixup.
# pcsclient.py fetch returns qeidentity and tdqeidentity as JSON-encoded strings.
# KBS expects them as parsed JSON structs. Empty strings are deleted; non-empty
# strings are parsed with fromjson. Without this fixup KBS fails with:
#   "collateral JSON error: invalid type: string "", expected struct QeIdentity"
# Per Red Hat OSC 1.13 disconnected TDX collateral procedure.
jq '
.collaterals |= (
    del(.qeidentity | select(. == ""))
    | del(.tdqeidentity | select(. == ""))
    | del(.qveidentity | select(. == ""))
    | del(.qeidentity_early | select(. == ""))
    | del(.tdqeidentity_early | select(. == ""))
    | del(.qveidentity_early | select(. == ""))
    | if .qeidentity then .qeidentity |= fromjson else . end
    | if .tdqeidentity then .tdqeidentity |= fromjson else . end
    | if .qveidentity then .qveidentity |= fromjson else . end
    | if .qeidentity_early then .qeidentity_early |= fromjson else . end
    | if .tdqeidentity_early then .tdqeidentity_early |= fromjson else . end
    | if .qveidentity_early then .qveidentity_early |= fromjson else . end
)
' "$RAW_FILE" > "$OUTPUT_FILE"

# Step 3: Verify identity fields are structs (not strings).
# -t early produces *_early variants; standard variants will be absent/deleted.
python3 - <<PYEOF
import json, sys
c = json.load(open("${OUTPUT_FILE}"))
col = c.get("collaterals", {})
ok = True
# Check all identity variants — at least one qe* and one tdqe* must be a dict
checks = [
    ("qeidentity",         col.get("qeidentity")),
    ("tdqeidentity",       col.get("tdqeidentity")),
    ("qeidentity_early",   col.get("qeidentity_early")),
    ("tdqeidentity_early", col.get("tdqeidentity_early")),
    ("qveidentity_early",  col.get("qveidentity_early")),
]
for name, val in checks:
    if val is None:
        print("  " + name + ": absent (deleted or not fetched)")
    elif isinstance(val, dict):
        print("  PASS " + name + ": dict with " + str(len(val)) + " keys")
    else:
        print("  WARN " + name + ": " + type(val).__name__ + " — unexpected type")
        ok = False

# Must have at least one qe*identity as a dict
has_qei = any(isinstance(col.get(k), dict) for k in ("qeidentity", "qeidentity_early"))
has_tdqei = any(isinstance(col.get(k), dict) for k in ("tdqeidentity", "tdqeidentity_early"))
if not has_qei:
    print("FAIL: no qeidentity or qeidentity_early dict — KBS will reject attestation")
    ok = False
if not has_tdqei:
    print("FAIL: no tdqeidentity or tdqeidentity_early dict — TDX attestation will fail")
    ok = False
sys.exit(0 if ok else 1)
PYEOF

FILE_SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
echo ""
echo "Success! Collateral collected and fixup applied."
echo "  File: $OUTPUT_FILE ($FILE_SIZE bytes)"
echo ""
echo "Next step: Load into Vault via:"
echo "  make load-secrets"
echo ""
echo "Note: Collateral expires in ~30-90 days. Re-run this script to refresh."
