#!/usr/bin/env bash
# Tests for configure_cluster_trusted_ca (step 7 of
# scripts/airgap-post-install.sh — runbook C-3): the functions are
# extracted with sed and run against a mocked `oc` with real output
# shapes; certificates are real openssl-generated PEMs. Each case has
# its own section header below.
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

for fn in configure_cluster_trusted_ca read_cluster_field cert_fingerprints; do
    sed -n "/^${fn}() {/,/^}\$/p" "$SCRIPT" > "${WORK}/func-${fn}.sh"
    grep -q "^${fn}() {" "${WORK}/func-${fn}.sh" \
        || { echo "FAIL: could not extract ${fn}"; exit 1; }
done

# ── Real certificates ────────────────────────────────────────────────
# Two real self-signed CAs for the user bundle, one unrelated "system" CA.
for i in 1 2 sys; do
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj "/CN=test-ca-${i}" \
        -keyout "${WORK}/ca-${i}.key" -out "${WORK}/ca-${i}.pem" \
        >/dev/null 2>&1 || { echo "openssl fixture failed"; exit 1; }
done
CA_DATA="$(cat "${WORK}/ca-1.pem" "${WORK}/ca-2.pem")"
OTHER_CA="$(cat "${WORK}/ca-sys.pem")"

# ── The oc mock (REAL output shapes) ─────────────────────────────────
# State: trustedca (current anchor), rv (resourceVersion), injected
# (injected ConfigMap data), list_rounds (listing poll counter).
# Failure injection: OC_FAIL_CM_GET / OC_FAIL_PROXY_GET / OC_FAIL_PATCH /
# OC_FAIL_PATCH_TEST / OC_CONCURRENT_ANCHOR / OC_DELAY_ROUNDS.
mkdir -p "${WORK}/bin" "${WORK}/state"
: > "${WORK}/state/trustedca"
echo "100" > "${WORK}/state/rv"
: > "${WORK}/state/injected"
echo "0" > "${WORK}/state/list_rounds"

cat > "${WORK}/bin/oc" <<'MOCK'
#!/usr/bin/env bash
STATE="$(dirname "$(dirname "$(readlink -f "$0")")")/state"
echo "$*" >> "${OC_CALLS:?}"
case "$*" in
    # proxy/cluster as a full JSON object — the real -o json shape.
    "get proxy cluster -o json")
        [[ -n "${OC_FAIL_PROXY_GET:-}" ]] && exit 1
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
        [[ -n "${OC_FAIL_PATCH:-}" ]] && { echo "mock patch failure" >&2; exit 1; }
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
        [[ -n "${OC_FAIL_CM_GET:-}" ]] && exit 1
        printf '%s' "${OC_CA_DATA:-}"
        exit 0 ;;
    # Structured ConfigMap listing — the real jsonpath range shape
    # ("ns name" per line); OC_DELAY_ROUNDS delays first appearance.
    "get configmaps -A -l config.openshift.io/inject-trusted-cabundle=true -o "*)
        rounds=$(cat "${STATE}/list_rounds")
        echo $(( rounds + 1 )) > "${STATE}/list_rounds"
        if [[ -n "${OC_DELAY_ROUNDS:-}" && $(( rounds + 1 )) -lt "${OC_DELAY_ROUNDS}" ]] \
            || [[ -z "$(cat "${STATE}/injected")" ]]; then
            exit 0
        fi
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
        export OC_CA_DATA="${OC_CA_DATA:-}" OC_FAIL_CM_GET="${OC_FAIL_CM_GET:-}" \
               OC_FAIL_PROXY_GET="${OC_FAIL_PROXY_GET:-}" OC_FAIL_PATCH="${OC_FAIL_PATCH:-}" \
               OC_FAIL_PATCH_TEST="${OC_FAIL_PATCH_TEST:-}" OC_CONCURRENT_ANCHOR="${OC_CONCURRENT_ANCHOR:-}" \
               OC_DELAY_ROUNDS="${OC_DELAY_ROUNDS:-}" \
               CA_RECONCILE_TIMEOUT_SECONDS="${CA_RECONCILE_TIMEOUT_SECONDS:-180}" \
               CA_RECONCILE_POLL_SECONDS="${CA_RECONCILE_POLL_SECONDS:-15}"
        export PATTERN_DIR="${WORK}/pattern"
        # shellcheck disable=SC1090
        source "${WORK}/helpers.sh"
        # shellcheck disable=SC1090
        source "${WORK}/func-read_cluster_field.sh"
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
    echo "0" > "${WORK}/state/list_rounds"
    : > "$OC_CALLS"
    OC_FAIL_CM_GET="" OC_FAIL_PROXY_GET="" OC_FAIL_PATCH=""
    OC_FAIL_PATCH_TEST="" OC_CONCURRENT_ANCHOR="" OC_DELAY_ROUNDS=""
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

# ── 2. Empty CA data → exit 1, no patch ─────────────────────────────
reset_state
OC_CA_DATA=""
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "no ca-bundle.crt data" "$ERR"; then
    ok "empty user-ca-bundle refused (no patch, exit 1)"
else
    bad "empty CA data: RC=$RC patches=$(patch_calls)"
fi

# ── 3. Non-PEM CA data → exit 1, no patch ───────────────────────────
reset_state
OC_CA_DATA="not a certificate at all"
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "does not parse as certificates" "$ERR"; then
    ok "non-PEM user-ca-bundle refused by openssl validation (no patch, exit 1)"
else
    bad "non-PEM CA data: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$ERR" | head -4
fi

# ── 3b. PEM-looking but unparseable (openssl rejects a block) ───────
reset_state
OC_CA_DATA="-----BEGIN CERTIFICATE-----
Zm9vYmFyCg==
-----END CERTIFICATE-----"
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "does not parse as certificates" "$ERR"; then
    ok "garbage certificate body refused by openssl (no patch, exit 1)"
else
    bad "garbage cert body: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$ERR" | head -4
fi

# ── 4. Failed bundle read → exit 1, no patch ────────────────────────
reset_state
OC_FAIL_CM_GET=1
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "Cannot read configmap user-ca-bundle" "$ERR"; then
    ok "failed bundle read aborts (failed read ≠ empty, exit 1)"
else
    bad "failed bundle read: RC=$RC patches=$(patch_calls)"
fi
OC_FAIL_CM_GET=""

# ── 5. Failed proxy read → exit 1, no patch ─────────────────────────
reset_state
OC_FAIL_PROXY_GET=1
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "Cannot read proxy/cluster" "$ERR"; then
    ok "failed proxy read aborts (exit 1, no blind patch)"
else
    bad "failed proxy read: RC=$RC patches=$(patch_calls)"
fi
OC_FAIL_PROXY_GET=""

# ── 6. Patch failure → exit 1, propagated ───────────────────────────
reset_state
OC_FAIL_PATCH=1
run_func
if [[ "$RC" == "1" && "$(patch_calls)" == "1" ]] \
    && grep -q "patch failed" "$ERR"; then
    ok "patch failure propagated (exit 1)"
else
    bad "patch failure: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$ERR" | head -4
fi
OC_FAIL_PATCH=""

# ── 6b. Concurrent anchor change at patch time → not overwritten ────
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

# ── 7. Already anchored + reconciled → exit 0, no patch ─────────────
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

# ── 8. Fresh anchor, reconciled → exit 0, patched once ──────────────
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

# ── 9. Delayed injection (appears on round 2) → exit 0, waited ──────
reset_state
CA_RECONCILE_POLL_SECONDS=1
OC_DELAY_ROUNDS=2
printf '%s' "$CA_DATA" > "${WORK}/state/injected"
run_func
if [[ "$RC" == "0" && "$(patch_calls)" == "1" ]] \
    && grep -q "Bundle reconciled" "$OUT" \
    && [[ "$(cat "${WORK}/state/list_rounds")" -ge 2 ]]; then
    ok "delayed injection: reconciled on a later round (re-list per round works, exit 0)"
else
    bad "delayed injection: RC=$RC patches=$(patch_calls) rounds=$(cat "${WORK}/state/list_rounds")"
    sed 's/^/    /' "$OUT" | head -8; sed 's/^/    /' "$ERR" | head -4
fi
OC_DELAY_ROUNDS=""

# ── 10. Genuine timeout (never injected) → exit 1 ───────────────────
reset_state
CA_RECONCILE_TIMEOUT_SECONDS=2 CA_RECONCILE_POLL_SECONDS=1
printf '%s' "$OTHER_CA" > "${WORK}/state/injected"   # injected bundle ≠ user CA
run_func
if [[ "$RC" == "1" ]] \
    && grep -q "picked up the user CA within" "$ERR"; then
    ok "genuine timeout: unrelated injected bundle never matches, exit 1"
else
    bad "genuine timeout: RC=$RC"
    sed 's/^/    /' "$OUT" | head -6; sed 's/^/    /' "$ERR" | head -6
fi

# ── 11. Partial injection (only one of two CAs) → still a timeout ───
reset_state
CA_RECONCILE_TIMEOUT_SECONDS=2 CA_RECONCILE_POLL_SECONDS=1
printf '%s' "$(cat "${WORK}/ca-1.pem")" > "${WORK}/state/injected"
run_func
if [[ "$RC" == "1" ]] && grep -q "picked up the user CA within" "$ERR"; then
    ok "fingerprint completeness: half-injected bundle (1 of 2 CAs) does not pass"
else
    bad "partial injection: RC=$RC"
fi

echo
echo "trusted-CA tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
