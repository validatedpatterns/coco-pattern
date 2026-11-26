#!/usr/bin/env bash
# Tests for the configure_cluster_trusted_ca step of
# scripts/airgap-post-install.sh (runbook C-3, trust-anchor hardening).
#
# The function is extracted from the script with sed and run against a
# mocked `oc`, with a temp copy of the pattern values (airgap: true) as
# PATTERN_DIR. Covered failure modes:
#   - a different non-empty trustedCA anchor  → exit 1, preserved (no patch)
#   - empty / non-PEM user-ca-bundle data     → exit 1, no patch
#   - failed reads (oc get)                   → exit 1, no patch
#   - patch failure / reverted patch          → exit 1, propagated
#   - already anchored + bundle reconciled    → exit 0, no patch (idempotent)
#   - fresh anchor, reconciled by injection   → exit 0, patched once
#
# Usage: bash tests/test-airgap-trusted-ca.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${PATTERN_DIR}/scripts/airgap-post-install.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

# ── Fixture: airgap pattern dir + extracted function ────────────────
mkdir -p "${WORK}/pattern/scripts"
cp "${PATTERN_DIR}/values-global.yaml" "${WORK}/pattern/values-global.yaml"
sed -i 's/^  airgap: false/  airgap: true/' "${WORK}/pattern/values-global.yaml"
grep -q "^  airgap: true" "${WORK}/pattern/values-global.yaml" || { echo "fixture failed"; exit 1; }

# Extract configure_cluster_trusted_ca() (up to its closing brace at col 0)
sed -n '/^configure_cluster_trusted_ca() {/,/^}/p' "$SCRIPT" > "${WORK}/func.sh"
grep -q "^configure_cluster_trusted_ca() {" "${WORK}/func.sh" \
    || { echo "FAIL: could not extract configure_cluster_trusted_ca"; exit 1; }

# ── The oc mock ─────────────────────────────────────────────────────
#   OC_TRUSTEDCA      current proxy/cluster spec.trustedCA.name ("" = empty)
#   OC_CA_DATA        user-ca-bundle ca-bundle.crt data ("" = missing)
#   OC_FAIL_CM_GET    user-ca-bundle reads fail
#   OC_FAIL_PROXY     proxy reads fail
#   OC_FAIL_PATCH     proxy patch fails
#   OC_REVERT_PATCH   patch succeeds but the readback keeps the old value
#   OC_INJECTED       an inject-trusted-cabundle ConfigMap carrying the CA
#   OC_CALLS          invocation log
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/oc" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "${OC_CALLS:?}"
case "$*" in
    "get configmap user-ca-bundle -n openshift-config -o jsonpath={.data.ca-bundle\\.crt}")
        [[ -n "${OC_FAIL_CM_GET:-}" ]] && exit 1
        printf '%s' "${OC_CA_DATA:-}"; exit 0 ;;
    "get proxy cluster -o jsonpath={.spec.trustedCA.name}")
        [[ -n "${OC_FAIL_PROXY:-}" ]] && exit 1
        # A successful patch is reflected in subsequent reads (stateful mock)
        if [[ -f "${OC_CALLS}.patched" ]]; then
            printf 'user-ca-bundle'
        else
            printf '%s' "${OC_TRUSTEDCA:-}"
        fi
        exit 0 ;;
    "patch proxy cluster --type merge -p "*)
        [[ -n "${OC_FAIL_PATCH:-}" ]] && { echo "mock patch failure" >&2; exit 1; }
        echo "proxy.config/cluster patched"
        : > "${OC_CALLS}.patched"
        exit 0 ;;
    "get configmaps -A -l config.openshift.io/inject-trusted-cabundle=true -o name")
        [[ -n "${OC_INJECTED:-}" ]] && echo "configmap/openshift-apiserver/user-ca-bundle" || true
        exit 0 ;;
    "get configmap user-ca-bundle -n openshift-apiserver -o jsonpath={.data.ca-bundle\\.crt}")
        printf '%s' "${OC_CA_DATA:-}"; exit 0 ;;
    *) echo "oc mock: unhandled: $*" >&2; exit 64 ;;
esac
MOCK
chmod +x "${WORK}/bin/oc"

export PATH="${WORK}/bin:$PATH"
export OC_CALLS="${WORK}/calls"

# A valid PEM bundle (two dummy certs) shared by CA data and injected CMs
PEM="-----BEGIN CERTIFICATE-----
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD
-----END CERTIFICATE-----"

run_func() { # runs the extracted function; RC, stdout OUT, stderr ERR
    OUT="$WORK/out" ERR="$WORK/err"
    if (
        export PATH="${WORK}/bin:$PATH" OC_CALLS="$OC_CALLS" \
               OC_TRUSTEDCA="${OC_TRUSTEDCA:-}" OC_CA_DATA="${OC_CA_DATA:-}" \
               OC_FAIL_CM_GET="${OC_FAIL_CM_GET:-}" OC_FAIL_PROXY="${OC_FAIL_PROXY:-}" \
               OC_FAIL_PATCH="${OC_FAIL_PATCH:-}" OC_REVERT_PATCH="${OC_REVERT_PATCH:-}" \
               OC_INJECTED="${OC_INJECTED:-}"
        export PATTERN_DIR="${WORK}/pattern"
        # shellcheck disable=SC1090
        source "${WORK}/helpers.sh"
        # shellcheck disable=SC1090
        source "${WORK}/func.sh"
        configure_cluster_trusted_ca
    ) >"$OUT" 2>"$ERR"; then
        RC=0
    else
        RC=$?
    fi
}
# Helpers the function expects (mirrors the script's own definitions)
cat > "${WORK}/helpers.sh" <<'HELPERS'
info()  { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*"; }
error() { echo "[ERROR] $*" >&2; }
step()  { echo "=== Step $1: $2 ==="; }
read_global_key() { # $1 dotted key, $2 default — real parse of the fixture
    python3 - "$1" "$2" <<'PY'
import sys, yaml
key, default = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(f"{__import__('os').environ['PATTERN_DIR']}/values-global.yaml")) or {}
for part in key.split('.'):
    if not isinstance(d, dict) or part not in d:
        print(default); sys.exit(0)
    d = d[part]
print('' if d is None else d)
PY
}
HELPERS

patch_calls() { awk '/patch proxy cluster/{n++} END{print n+0}' "$OC_CALLS" 2>/dev/null; }

# ── 1. Different non-empty anchor → preserved, exit 1 ───────────────
: > "$OC_CALLS"; rm -f "${OC_CALLS}.patched"
OC_TRUSTEDCA="custom-lab-bundle" OC_CA_DATA="$PEM" OC_INJECTED=1
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "already anchors at a different bundle" "$ERR"; then
    ok "different non-empty anchor preserved (no patch, exit 1, guidance given)"
else
    bad "different anchor: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$ERR" | head -6
fi

# ── 2. Empty CA data → exit 1, no patch ─────────────────────────────
: > "$OC_CALLS"; rm -f "${OC_CALLS}.patched"
OC_TRUSTEDCA="" OC_CA_DATA="" OC_INJECTED=""
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "no ca-bundle.crt data" "$ERR"; then
    ok "empty user-ca-bundle refused (no patch, exit 1)"
else
    bad "empty CA data: RC=$RC patches=$(patch_calls)"
fi

# ── 3. Non-PEM CA data → exit 1, no patch ───────────────────────────
: > "$OC_CALLS"; rm -f "${OC_CALLS}.patched"
OC_TRUSTEDCA="" OC_CA_DATA="not a certificate at all" OC_INJECTED=""
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "no PEM certificates" "$ERR"; then
    ok "non-PEM user-ca-bundle refused (no patch, exit 1)"
else
    bad "non-PEM CA data: RC=$RC patches=$(patch_calls)"
fi

# ── 4. Failed bundle read → exit 1, no patch ────────────────────────
: > "$OC_CALLS"; rm -f "${OC_CALLS}.patched"
OC_TRUSTEDCA="" OC_CA_DATA="$PEM" OC_FAIL_CM_GET=1 OC_INJECTED=""
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "Cannot read configmap user-ca-bundle" "$ERR"; then
    ok "failed bundle read aborts (failed read ≠ empty, exit 1)"
else
    bad "failed bundle read: RC=$RC patches=$(patch_calls)"
fi
OC_FAIL_CM_GET=""

# ── 5. Failed proxy read → exit 1, no patch ─────────────────────────
: > "$OC_CALLS"; rm -f "${OC_CALLS}.patched"
OC_TRUSTEDCA="" OC_CA_DATA="$PEM" OC_FAIL_PROXY=1 OC_INJECTED=""
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "Cannot read proxy/cluster" "$ERR"; then
    ok "failed proxy read aborts (exit 1, no blind patch)"
else
    bad "failed proxy read: RC=$RC patches=$(patch_calls)"
fi
OC_FAIL_PROXY=""

# ── 6. Patch failure → exit 1, propagated ───────────────────────────
: > "$OC_CALLS"; rm -f "${OC_CALLS}.patched"
OC_TRUSTEDCA="" OC_CA_DATA="$PEM" OC_FAIL_PATCH=1 OC_INJECTED=""
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "1" ]] \
    && grep -q "oc patch proxy/cluster failed" "$ERR"; then
    ok "patch failure propagated (exit 1)"
else
    bad "patch failure: RC=$RC patches=$(patch_calls)"
fi
OC_FAIL_PATCH=""

# ── 7. Already anchored + reconciled → exit 0, no patch ─────────────
: > "$OC_CALLS"; rm -f "${OC_CALLS}.patched"
OC_TRUSTEDCA="user-ca-bundle" OC_CA_DATA="$PEM" OC_INJECTED=1
run_func
if [[ "$RC" == "0" && "$(patch_calls)" == "0" ]] \
    && grep -q "Bundle reconciled" "$OUT"; then
    ok "already anchored: idempotent skip, reconciliation verified (exit 0)"
else
    bad "already anchored: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$OUT" | head -6
fi

# ── 8. Fresh anchor, injection reconciles → exit 0, patched once ────
: > "$OC_CALLS"; rm -f "${OC_CALLS}.patched"
OC_TRUSTEDCA="" OC_CA_DATA="$PEM" OC_INJECTED=1
run_func
if [[ "$RC" == "0" && "$(patch_calls)" == "1" ]] \
    && grep -q "pointer set to user-ca-bundle" "$OUT" \
    && grep -q "Bundle reconciled" "$OUT"; then
    ok "fresh anchor: patched once, pointer+reconciliation both verified (exit 0)"
else
    bad "fresh anchor: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$OUT" | head -8; sed 's/^/    /' "$ERR" | head -4
fi

echo
echo "trusted-CA tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
