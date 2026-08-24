#!/usr/bin/env bash
# Check expiry of PCK cache secrets and platform data in intel-dcap-operator-system.
#
# PCK cache secrets contain a binary blob from pcsclient.py with embedded
# JSON TCB info including nextUpdate dates. This script extracts and checks them.
#
# Usage:
#   ./scripts/check-pck-expiry.sh
#
# Requires: oc (logged in), python3, base64

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NS="${1:-intel-dcap-operator-system}"

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

# ── PCK Cache Secrets ────────────────────────────────────────────────────────

echo "=== PCK Cache Secrets (${NS}) ==="

PCK_SECRETS=$(oc get secrets -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E '^[0-9a-f]{32}-pck$' || true)

if [ -z "$PCK_SECRETS" ]; then
    echo -e "  ${RED}MISSING${NC}  No PCK cert secrets found (expected <qe_id>-pck)"
    fail=1
else
    for secret_name in $PCK_SECRETS; do
        qe_id="${secret_name%-pck}"
        echo "  PCK secret: ${secret_name} (QE ID: ${qe_id})"

        # The PCK cache blob contains URL-encoded PEM X.509 certs + embedded JSON TCB info
        oc get secret "$secret_name" -n "$NS" -o jsonpath='{.data.certificate}' | \
            base64 -d | python3 -c "
import sys, re, subprocess, urllib.parse
data = sys.stdin.buffer.read()
text = data.decode('ascii', errors='ignore')

# X.509 certificate expiry
decoded = urllib.parse.unquote(text)
certs = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', decoded, re.DOTALL)
pck_expiries = []
for cert in certs:
    r = subprocess.run(['openssl', 'x509', '-noout', '-subject', '-enddate'],
        input=cert, capture_output=True, text=True)
    if r.returncode == 0:
        lines = r.stdout.strip().split('\n')
        subj = lines[0].replace('subject=', '').strip()
        end = lines[1].replace('notAfter=', '').strip() if len(lines) > 1 else ''
        if 'PCK Certificate' in subj:
            pck_expiries.append(end)
        elif end:
            print(f'CERT|{subj}|{end}')
if pck_expiries:
    print(f'CERT|PCK Certificate (x{len(pck_expiries)})|{pck_expiries[0]}')

# TCB info nextUpdate
for m in re.findall(r'\"nextUpdate\":\"([^\"]+)\"', text):
    print(f'TCB|{m}')

if not certs and not re.search(r'nextUpdate', text):
    print('NONE')
" | while IFS='|' read -r rtype val1 val2; do
            case "$rtype" in
                NONE)
                    echo -e "    ${YELLOW}UNKNOWN${NC}  No expiry data found in PCK cache blob"
                    ;;
                CERT)
                    iso=$(python3 -c "
from datetime import datetime
try:
    dt = datetime.strptime('$val2', '%b %d %H:%M:%S %Y %Z')
except ValueError:
    dt = datetime.strptime('$val2', '%b  %d %H:%M:%S %Y %Z')
print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null)
                    [ -n "$iso" ] && check_date "    cert: $val1" "$iso"
                    ;;
                TCB)
                    check_date "    TCB nextUpdate" "$val1"
                    ;;
            esac
        done
    done
fi

# ── Platform Data ────────────────────────────────────────────────────────────

echo ""
echo "=== Platform Data (${NS}) ==="

PLATFORM_SECRETS=$(oc get secrets -n "$NS" -l type=platform-data --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)

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
    echo -e "${RED}RESULT: ISSUES FOUND${NC}"
    exit 1
else
    echo -e "${GREEN}RESULT: ALL OK${NC}"
fi
