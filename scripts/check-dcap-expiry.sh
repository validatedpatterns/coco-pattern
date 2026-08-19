#!/usr/bin/env bash
# Check expiry status of TDX DCAP collateral and PCK certificates deployed on the cluster.
#
# Checks:
#   1. platform_collaterals.json in trustee-operator-system (TCB info, QE identity expiry)
#   2. PCK cache secrets in intel-dcap-operator-system (embedded TCB info expiry)
#
# Usage:
#   ./scripts/check-dcap-expiry.sh
#
# Requires: oc (logged in), python3, base64

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

COLLATERAL_NS="trustee-operator-system"
COLLATERAL_SECRET="tdx-collateral"
PCK_NS="intel-dcap-operator-system"

fail=0

check_date() {
    local label="$1" next_update="$2"
    local expiry_epoch now_epoch days_left
    expiry_epoch=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('${next_update}'.replace('Z','+00:00')).timestamp()))")
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [ "$days_left" -lt 0 ]; then
        echo -e "  ${RED}EXPIRED${NC}  ${label}: nextUpdate=${next_update} (${days_left}d ago)"
        fail=1
    elif [ "$days_left" -lt 7 ]; then
        echo -e "  ${YELLOW}EXPIRING${NC} ${label}: nextUpdate=${next_update} (${days_left}d left)"
    else
        echo -e "  ${GREEN}OK${NC}       ${label}: nextUpdate=${next_update} (${days_left}d left)"
    fi
}

# ── 1. DCAP Collateral (platform_collaterals.json) ──────────────────────────

echo "=== DCAP Collateral (${COLLATERAL_NS}/${COLLATERAL_SECRET}) ==="

if ! oc get secret "$COLLATERAL_SECRET" -n "$COLLATERAL_NS" &>/dev/null; then
    echo -e "  ${RED}MISSING${NC}  Secret ${COLLATERAL_SECRET} not found in ${COLLATERAL_NS}"
    fail=1
else
    COLLATERAL_JSON=$(oc get secret "$COLLATERAL_SECRET" -n "$COLLATERAL_NS" \
        -o jsonpath='{.data.platform_collaterals\.json}' | base64 -d)

    python3 -c "
import json, sys

data = json.loads('''${COLLATERAL_JSON}'''.replace(\"'''\", ''))
" 2>/dev/null || {
        # Fallback: pipe through stdin for large JSON
        true
    }

    # Extract TCB info expiry dates
    echo "$COLLATERAL_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
col = data.get('collaterals', {})
results = []

# TCB info entries
for ti in col.get('tcbinfos', []):
    fmspc = ti.get('fmspc', 'unknown')
    for key in ['sgx_tcbinfo_early', 'sgx_tcbinfo', 'tdx_tcbinfo_early', 'tdx_tcbinfo']:
        info = ti.get(key, {})
        if isinstance(info, dict):
            tcb = info.get('tcbInfo', {})
        else:
            continue
        nu = tcb.get('nextUpdate')
        if nu:
            results.append((f'{key} FMSPC={fmspc}', nu))

# QE identity entries
for qi in col.get('qeidentities', []):
    for key in ['qe_identity_early', 'qe_identity']:
        ei = qi.get(key, {})
        if isinstance(ei, str):
            try:
                ei = json.loads(ei)
            except json.JSONDecodeError:
                continue
        if isinstance(ei, dict):
            info = ei.get('enclaveIdentity', {})
            nu = info.get('nextUpdate')
            if nu:
                results.append((f'{key}', nu))

for label, nu in results:
    print(f'{label}|{nu}')
" | while IFS='|' read -r label next_update; do
        check_date "$label" "$next_update"
    done

    echo ""
fi

# ── 2. PCK Certificates (intel-dcap-operator-system) ─────────────────────────

echo "=== PCK Cache Secrets (${PCK_NS}) ==="

PCK_SECRETS=$(oc get secrets -n "$PCK_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E '^[0-9a-f]{32}-pck$' || true)

if [ -z "$PCK_SECRETS" ]; then
    echo -e "  ${RED}MISSING${NC}  No PCK cert secrets found (expected <qe_id>-pck)"
    fail=1
else
    for secret_name in $PCK_SECRETS; do
        qe_id="${secret_name%-pck}"
        echo "  PCK secret: ${secret_name} (QE ID: ${qe_id})"

        # The PCK cache secret is a binary blob with embedded JSON TCB info
        oc get secret "$secret_name" -n "$PCK_NS" -o jsonpath='{.data.certificate}' | \
            base64 -d | python3 -c "
import sys, re
data = sys.stdin.buffer.read()
text = data.decode('ascii', errors='ignore')
matches = re.findall(r'\"nextUpdate\":\"([^\"]+)\"', text)
if matches:
    for m in matches:
        print(m)
else:
    print('NONE')
" | while read -r next_update; do
            if [ "$next_update" = "NONE" ]; then
                echo -e "    ${YELLOW}UNKNOWN${NC}  No expiry date found in PCK cache blob"
            else
                check_date "    embedded TCB" "$next_update"
            fi
        done
    done
fi

# ── 3. Platform Data Secret ──────────────────────────────────────────────────

echo ""
echo "=== Platform Data (${PCK_NS}) ==="

PLATFORM_SECRETS=$(oc get secrets -n "$PCK_NS" -l type=platform-data --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)

if [ -z "$PLATFORM_SECRETS" ]; then
    echo -e "  ${RED}MISSING${NC}  No platform-data secrets found"
    fail=1
else
    for ps in $PLATFORM_SECRETS; do
        echo -e "  ${GREEN}OK${NC}       QE ID: ${ps}"
    done
fi

echo ""
if [ "$fail" -ne 0 ]; then
    echo -e "${RED}RESULT: ISSUES FOUND${NC} — see above"
    exit 1
else
    echo -e "${GREEN}RESULT: ALL OK${NC}"
fi
