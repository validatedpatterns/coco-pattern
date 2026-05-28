#!/usr/bin/env bash
# Collect firmware reference values from veritas output and push to Vault
#
# Usage:
#   ./scripts/collect-firmware-refvals.sh <refvals-file.json>
#
# Prerequisites:
#   - jq installed
#   - vault CLI installed and authenticated
#   - VAULT_ADDR environment variable set (or infer from oc)
#   - veritas output JSON file from bare metal kata pod

set -euo pipefail

# Check prerequisites
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed." >&2; exit 1; }
command -v vault >/dev/null 2>&1 || { echo "Error: vault CLI is required but not installed." >&2; exit 1; }

# Validate arguments
if [ $# -ne 1 ]; then
    echo "Usage: $0 <refvals-file.json>" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 ./refvals-ocp-4.18.json" >&2
    exit 1
fi

REFVALS_FILE="$1"

if [ ! -f "$REFVALS_FILE" ]; then
    echo "Error: File not found: $REFVALS_FILE" >&2
    exit 1
fi

# Infer VAULT_ADDR from cluster if not set
if [ -z "${VAULT_ADDR:-}" ]; then
    if command -v oc >/dev/null 2>&1; then
        VAULT_ROUTE=$(oc get route -n vault vault -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
        if [ -n "$VAULT_ROUTE" ]; then
            export VAULT_ADDR="https://${VAULT_ROUTE}"
            echo "Inferred VAULT_ADDR from cluster: $VAULT_ADDR"
        else
            echo "Error: VAULT_ADDR not set and could not infer from cluster" >&2
            exit 1
        fi
    else
        echo "Error: VAULT_ADDR not set and oc CLI not available" >&2
        exit 1
    fi
fi

# Check Vault authentication
if ! vault token lookup >/dev/null 2>&1; then
    echo "Error: Not authenticated to Vault. Set VAULT_TOKEN or run 'vault login'" >&2
    exit 1
fi

echo "Processing firmware reference values from: $REFVALS_FILE"

# Extract measurements from veritas JSON
# Veritas format varies by TEE type - handle both TDX and SNP
# We extract into separate variables then merge

# TDX measurements (if present)
MR_TD=$(jq -r '.tdx.mr_td // empty' "$REFVALS_FILE" 2>/dev/null || echo "")
RTMR_1=$(jq -r '.tdx.rtmr[1] // empty' "$REFVALS_FILE" 2>/dev/null || echo "")
RTMR_2=$(jq -r '.tdx.rtmr[2] // empty' "$REFVALS_FILE" 2>/dev/null || echo "")
XFAM=$(jq -r '.tdx.xfam // empty' "$REFVALS_FILE" 2>/dev/null || echo "")

# SNP measurements (if present)
SNP_LAUNCH=$(jq -r '.snp.launch_measurement // empty' "$REFVALS_FILE" 2>/dev/null || echo "")

# Build JSON payload for Vault
# Each field is an array to support multiple valid values (multi-version support)
VAULT_PAYLOAD=$(jq -n \
    --arg mr_td "$MR_TD" \
    --arg rtmr_1 "$RTMR_1" \
    --arg rtmr_2 "$RTMR_2" \
    --arg xfam "$XFAM" \
    --arg snp_launch "$SNP_LAUNCH" \
    '{
        mr_td: (if $mr_td != "" then [$mr_td] else [] end),
        rtmr_1: (if $rtmr_1 != "" then [$rtmr_1] else [] end),
        rtmr_2: (if $rtmr_2 != "" then [$rtmr_2] else [] end),
        xfam: (if $xfam != "" then [$xfam] else [] end),
        snp_launch_measurement: (if $snp_launch != "" then [$snp_launch] else [] end)
    }'
)

echo "Extracted firmware reference values:"
echo "$VAULT_PAYLOAD" | jq .

# Check if any values were extracted
VALUE_COUNT=$(echo "$VAULT_PAYLOAD" | jq '[.[] | select(length > 0)] | length')
if [ "$VALUE_COUNT" -eq 0 ]; then
    echo "Warning: No firmware measurements found in $REFVALS_FILE" >&2
    echo "Veritas output may be incomplete or in unexpected format" >&2
    exit 1
fi

# Merge with existing values if present
VAULT_PATH="secret/data/hub/firmwareReferenceValues"
echo "Checking for existing values at $VAULT_PATH..."

EXISTING_DATA=$(vault kv get -format=json "$VAULT_PATH" 2>/dev/null | jq -r '.data.data // {}' || echo "{}")

if [ "$EXISTING_DATA" != "{}" ]; then
    echo "Found existing firmware reference values"
    echo "Merging new values with existing..."

    # Merge arrays: union of existing and new values
    MERGED_PAYLOAD=$(jq -n \
        --argjson existing "$EXISTING_DATA" \
        --argjson new "$VAULT_PAYLOAD" \
        '$existing * $new |
         to_entries |
         map({
             key: .key,
             value: (.value | if type == "array" then unique else . end)
         }) |
         from_entries'
    )

    echo "Merged payload:"
    echo "$MERGED_PAYLOAD" | jq .
    FINAL_PAYLOAD="$MERGED_PAYLOAD"
else
    echo "No existing values found, will create new secret"
    FINAL_PAYLOAD="$VAULT_PAYLOAD"
fi

# Push to Vault
echo "Writing firmware reference values to Vault at $VAULT_PATH..."
echo "$FINAL_PAYLOAD" | vault kv put "$VAULT_PATH" -

if [ $? -eq 0 ]; then
    echo "✓ Successfully wrote firmware reference values to Vault"
    echo ""
    echo "Next steps:"
    echo "1. Verify the secret: vault kv get $VAULT_PATH"
    echo "2. On the cluster with KBS deployed, force ExternalSecret sync:"
    echo "   oc delete externalsecret firmware-refvals-eso -n trustee-operator-system"
    echo "3. Verify the secret was synced:"
    echo "   oc get secret firmware-reference-values -n trustee-operator-system"
else
    echo "✗ Failed to write to Vault" >&2
    exit 1
fi
