#!/usr/bin/env bash
# Tests for configure_cluster_trusted_ca (step 7 of
# scripts/airgap-post-install.sh — runbook C-3): the function is
# extracted with sed and run against a mocked `oc` with real output
# shapes; certificates are real openssl-generated PEMs.
#
# SCOPE — only the cases that guard genuinely dangerous behaviour:
#   1. a different, non-empty trust anchor is never clobbered
#   2. a concurrent anchor change at patch time is never overwritten
#   3. fresh anchor: patched exactly once, reconciliation verified
#   4. already anchored: idempotent no-op
# The wider matrix this suite used to carry (empty/garbage bundles, read
# failures, TOCTOU call counting, poll-loop timing, fingerprint
# completeness) was retired in review: those are straight-line guards,
# and asserting them through a hand-written oc mock mostly re-encoded
# our own assumptions about oc's output shapes — false confidence
# rather than coverage. The mock kept here is the minimum needed to
# drive the four stateful scenarios above.
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

command -v openssl >/dev/null 2>&1 || { echo "openssl required"; exit 1; }

# ── Fixture: airgap pattern dir + extracted functions ────────────────
mkdir -p "${WORK}/pattern"
cp "${PATTERN_DIR}/values-global.yaml" "${WORK}/pattern/values-global.yaml"
sed -i 's/^  airgap: false/  airgap: true/' "${WORK}/pattern/values-global.yaml"
grep -q "^  airgap: true" "${WORK}/pattern/values-global.yaml" || { echo "fixture failed"; exit 1; }

for fn in configure_cluster_trusted_ca read_cluster_field read_cluster_snapshot cert_fingerprints; do
    sed -n "/^${fn}() {/,/^}\$/p" "$SCRIPT" > "${WORK}/func-${fn}.sh"
    grep -q "^${fn}() {" "${WORK}/func-${fn}.sh" \
        || { echo "FAIL: could not extract ${fn}"; exit 1; }
done

# ── Real certificates: a two-CA user bundle ──────────────────────────
for i in 1 2; do
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj "/CN=test-ca-${i}" \
        -keyout "${WORK}/ca-${i}.key" -out "${WORK}/ca-${i}.pem" \
        >/dev/null 2>&1 || { echo "openssl fixture failed"; exit 1; }
done
CA_DATA="$(cat "${WORK}/ca-1.pem" "${WORK}/ca-2.pem")"

# ── The oc mock (REAL output shapes) ─────────────────────────────────
# State: trustedca (current anchor), rv (resourceVersion), injected
# (injected ConfigMap data). Failure injection: OC_FAIL_PATCH_TEST makes
# the API server reject the patch's resourceVersion test op, and
# OC_CONCURRENT_ANCHOR is the anchor a concurrent writer leaves behind.
mkdir -p "${WORK}/bin" "${WORK}/state"
: > "${WORK}/state/trustedca"
echo "100" > "${WORK}/state/rv"
: > "${WORK}/state/injected"

cat > "${WORK}/bin/oc" <<'MOCK'
#!/usr/bin/env bash
STATE="$(dirname "$(dirname "$(readlink -f "$0")")")/state"
echo "$*" >> "${OC_CALLS:?}"
case "$*" in
    # proxy/cluster as a full JSON object — the real -o json shape.
    "get proxy cluster -o json")
        tc=$(cat "${STATE}/trustedca")
        rv=$(cat "${STATE}/rv")
        printf '{"apiVersion":"config.openshift.io/v1","kind":"Proxy",'
        printf '"metadata":{"name":"cluster","resourceVersion":"%s"},' "$rv"
        if [[ -n "$tc" ]]; then
            printf '"spec":{"trustedCA":{"name":"%s"}}}' "$tc"
        else
            printf '"spec":{}}'
        fi
        exit 0 ;;
    # The conditional write: a JSON patch with a resourceVersion test op.
    "patch proxy cluster --type json -p "*)
        if [[ -n "${OC_FAIL_PATCH_TEST:-}" ]]; then
            # Simulate the API-server test-op failure (409 conflict): the
            # concurrent writer wins and bumps the resourceVersion.
            [[ -n "${OC_CONCURRENT_ANCHOR:-}" ]] \
                && printf '%s' "${OC_CONCURRENT_ANCHOR}" > "${STATE}/trustedca"
            echo "$(($(cat "${STATE}/rv") + 1))" > "${STATE}/rv"
            echo "Error from server: the server rejected our request due to an error in our request" >&2
            exit 1
        fi
        echo "proxy.config/cluster patched"
        printf 'user-ca-bundle' > "${STATE}/trustedca"
        echo "$(($(cat "${STATE}/rv") + 1))" > "${STATE}/rv"
        exit 0 ;;
    "get configmap user-ca-bundle -n openshift-config -o jsonpath={.data.ca-bundle\\.crt}")
        printf '%s' "${OC_CA_DATA:-}"
        exit 0 ;;
    # Structured ConfigMap listing — the real jsonpath range shape
    # ("ns name" per line).
    "get configmaps -A -l config.openshift.io/inject-trusted-cabundle=true -o "*)
        [[ -z "$(cat "${STATE}/injected")" ]] && exit 0
        echo "openshift-apiserver user-ca-bundle"
        exit 0 ;;
    "get configmap user-ca-bundle -n openshift-apiserver -o jsonpath={.data.ca-bundle\\.crt}")
        cat "${STATE}/injected"
        exit 0 ;;
    *) echo "oc mock: unhandled: $*" >&2; exit 64 ;;
esac
MOCK
chmod +x "${WORK}/bin/oc"

export OC_CALLS="${WORK}/calls"

run_func() { # runs the extracted step; RC, stdout OUT, stderr ERR
    OUT="$WORK/out" ERR="$WORK/err"
    if (
        export PATH="${WORK}/bin:$PATH" OC_CALLS="$OC_CALLS"
        export OC_CA_DATA="${OC_CA_DATA:-}" OC_FAIL_PATCH_TEST="${OC_FAIL_PATCH_TEST:-}" \
               OC_CONCURRENT_ANCHOR="${OC_CONCURRENT_ANCHOR:-}" \
               CA_RECONCILE_TIMEOUT_SECONDS="${CA_RECONCILE_TIMEOUT_SECONDS:-180}" \
               CA_RECONCILE_POLL_SECONDS="${CA_RECONCILE_POLL_SECONDS:-15}"
        export PATTERN_DIR="${WORK}/pattern"
        # shellcheck disable=SC1090
        source "${WORK}/helpers.sh"
        # shellcheck disable=SC1090
        source "${WORK}/func-read_cluster_field.sh"
        # shellcheck disable=SC1090
        source "${WORK}/func-read_cluster_snapshot.sh"
        # shellcheck disable=SC1090
        source "${WORK}/func-cert_fingerprints.sh"
        # shellcheck disable=SC1090
        source "${WORK}/func-configure_cluster_trusted_ca.sh"
        configure_cluster_trusted_ca
    ) >"$OUT" 2>"$ERR"; then
        RC=0
    else
        RC=$?
    fi
}
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
reset_state() {
    : > "${WORK}/state/trustedca"
    echo "100" > "${WORK}/state/rv"
    : > "${WORK}/state/injected"
    : > "$OC_CALLS"
    OC_FAIL_PATCH_TEST="" OC_CONCURRENT_ANCHOR=""
    OC_CA_DATA="$CA_DATA"
    CA_RECONCILE_TIMEOUT_SECONDS=180 CA_RECONCILE_POLL_SECONDS=15
}

# ── 1. Different non-empty anchor → preserved, exit 1 ───────────────
reset_state
printf 'custom-lab-bundle' > "${WORK}/state/trustedca"
printf '%s' "$CA_DATA" > "${WORK}/state/injected"
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "already anchors at a different bundle" "$ERR"; then
    ok "different non-empty anchor preserved (no patch, exit 1, guidance given)"
else
    bad "different anchor: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$ERR" | head -6
fi

# ── 2. Concurrent anchor change at patch time → not overwritten ────
reset_state
OC_FAIL_PATCH_TEST=1 OC_CONCURRENT_ANCHOR="someone-elses-bundle"
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "1" ]] \
    && grep -q "refusing to overwrite" "$ERR" \
    && [[ "$(cat "${WORK}/state/trustedca")" == "someone-elses-bundle" ]]; then
    ok "concurrent anchor change preserved (json-patch test failed, exit 1)"
else
    bad "concurrent anchor: RC=$RC patches=$(patch_calls) state=$(cat "${WORK}/state/trustedca")"
    sed 's/^/    /' "$ERR" | head -5
fi
OC_FAIL_PATCH_TEST="" OC_CONCURRENT_ANCHOR=""

# ── 3. Fresh anchor, reconciled → exit 0, patched once ──────────────
reset_state
printf '%s' "$CA_DATA" > "${WORK}/state/injected"
run_func
if [[ "$RC" == "0" && "$(patch_calls)" == "1" ]] \
    && grep -q "pointer set to user-ca-bundle" "$OUT" \
    && grep -q "Bundle reconciled" "$OUT"; then
    ok "fresh anchor: patched once, pointer+reconciliation both verified (exit 0)"
else
    bad "fresh anchor: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$OUT" | head -8; sed 's/^/    /' "$ERR" | head -4
fi

# ── 4. Already anchored + reconciled → exit 0, no patch ─────────────
reset_state
printf 'user-ca-bundle' > "${WORK}/state/trustedca"
printf '%s' "$CA_DATA" > "${WORK}/state/injected"
run_func
if [[ "$RC" == "0" && "$(patch_calls)" == "0" ]] \
    && grep -q "Bundle reconciled" "$OUT"; then
    ok "already anchored: idempotent skip, reconciliation verified (exit 0)"
else
    bad "already anchored: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$OUT" | head -6
fi

echo
echo "trusted-CA tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
