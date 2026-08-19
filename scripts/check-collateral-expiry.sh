#!/usr/bin/env bash
# Check expiry of TDX DCAP collateral deployed in trustee-operator-system.
#
# Parses platform_collaterals.json from the tdx-collateral Secret for
# TCB info and QE identity nextUpdate dates.
#
# Usage:
#   ./scripts/check-collateral-expiry.sh
#
# Requires: oc (logged in), python3, base64

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NS="${1:-trustee-operator-system}"
SECRET="${2:-tdx-collateral}"

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

echo "=== DCAP Collateral (${NS}/${SECRET}) ==="

if ! oc get secret "$SECRET" -n "$NS" &>/dev/null; then
    echo -e "  ${RED}MISSING${NC}  Secret ${SECRET} not found in ${NS}"
    exit 1
fi

oc get secret "$SECRET" -n "$NS" \
    -o jsonpath='{.data.platform_collaterals\.json}' | base64 -d | python3 -c "
import json, sys
data = json.load(sys.stdin)
col = data.get('collaterals', {})

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
            print(f'{key} FMSPC={fmspc}|{nu}')

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
                print(f'{key}|{nu}')
" | while IFS='|' read -r label next_update; do
    check_date "$label" "$next_update"
done

echo ""
if [ "$fail" -ne 0 ]; then
    echo -e "${RED}RESULT: ISSUES FOUND${NC}"
    exit 1
else
    echo -e "${GREEN}RESULT: ALL OK${NC}"
fi
