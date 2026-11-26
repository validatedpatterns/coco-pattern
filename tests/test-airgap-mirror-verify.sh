#!/usr/bin/env bash
# Unit test for the skopeo invocation in mirror_oci_charts (step 5):
# flat --cert-dir layout, --tls-verify=true with a CA configured,
# --authfile only (never --creds on argv), temp cert dir cleanup. Runs
# the sed-extracted function against mocked oc/skopeo (argv recorded)
# with a real self-signed CA.
#
# Usage: bash tests/test-airgap-mirror-verify.sh
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

# ── Extract the function ─────────────────────────────────────────────
sed -n '/^mirror_oci_charts() {/,/^}$/p' "$SCRIPT" > "${WORK}/func.sh"
grep -q "^mirror_oci_charts() {" "${WORK}/func.sh" \
    || { echo "FAIL: could not extract mirror_oci_charts"; exit 1; }

# ── A real CA that is not in the system trust store ──────────────────
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj "/CN=mirror-ca-not-in-system-trust" \
    -keyout "${WORK}/ca.key" -out "${WORK}/ca.pem" >/dev/null 2>&1 \
    || { echo "openssl fixture failed"; exit 1; }

# ── Fake HOME: pull-secret.json + the mirror CA at the runbook path ──
export HOME="${WORK}/home"
mkdir -p "${HOME}/.coco-pattern"
cp "${WORK}/ca.pem" "${HOME}/.coco-pattern/registry-ca-cert.pem"
cat > "${HOME}/pull-secret.json" <<'EOF'
{"auths":{"quay.example.com:443":{"auth":"dXNlcjpwYXNzd29yZA=="}}}
EOF

# ── Mocked oc (image mirror no-ops) and skopeo (records argv) ────────
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/oc" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    "image mirror "*) exit 0 ;;
    *) echo "oc mock: unhandled: $*" >&2; exit 64 ;;
esac
MOCK
cat > "${WORK}/bin/skopeo" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SKOPEO_ARGS:?}"
case "$*" in
    "list-tags docker://quay.io/validatedpatterns/pattern-install")
        echo '{"Tags":["0.0.19","0.0.20"]}'; exit 0 ;;
    "list-tags --authfile "*" --cert-dir "*" --tls-verify=true docker://"*)
        # Assert the cert-dir layout AT CALL TIME — the script cleans
        # the temp dir up when the step finishes.
        certdir=""
        prev=""
        for a in "$@"; do
            [[ "$prev" == "--cert-dir" ]] && certdir="$a"
            prev="$a"
        done
        verdict="certdir=${certdir}"
        if [[ -f "${certdir}/ca.crt" ]] \
            && cmp -s "${certdir}/ca.crt" "${TEST_CA:?}" \
            && ! compgen -G "${certdir}/*/" >/dev/null; then
            verdict="$verdict layout=FLAT content=MATCH"
        else
            verdict="$verdict layout=WRONG"
        fi
        printf '%s\n' "$verdict" >> "${SKOPEO_CERTDIR_VERDICT:?}"
        echo '{"Tags":["0.0.19","0.0.20"]}'; exit 0 ;;
    *) echo "skopeo mock: unhandled: $*" >&2; exit 64 ;;
esac
MOCK
chmod +x "${WORK}/bin/oc" "${WORK}/bin/skopeo"
export PATH="${WORK}/bin:$PATH"
export SKOPEO_ARGS="${WORK}/skopeo-args"
export SKOPEO_CERTDIR_VERDICT="${WORK}/certdir-verdict"
export TEST_CA="${WORK}/ca.pem"

# ── Run the step ─────────────────────────────────────────────────────
export MIRROR_REGISTRY="quay.example.com:443/mirror"
: > "$SKOPEO_CERTDIR_VERDICT"
: > "$SKOPEO_ARGS"
if (
    export PATH MIRROR_REGISTRY SKOPEO_ARGS PATTERN_DIR
    info()  { echo "[INFO] $*"; }
    warn()  { echo "[WARN] $*"; }
    error() { echo "[ERROR] $*" >&2; }
    step()  { echo "=== Step $1: $2 ==="; }
    read_global_key() { # real parse of the repo values (clusterVersion → 4.22)
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
    # shellcheck disable=SC1090
    source "${WORK}/func.sh"
    mirror_oci_charts
) >"${WORK}/out" 2>"${WORK}/err"; then
    rc=0
else
    rc=$?
fi

# ── Assertions on the recorded skopeo argv ───────────────────────────
verify_line="$(grep 'list-tags --authfile' "$SKOPEO_ARGS" | head -1)"

if [[ $rc -ne 0 ]]; then
    bad "mirror_oci_charts exited $rc"
    sed 's/^/    /' "${WORK}/err" | head -8
elif [[ -z "$verify_line" ]]; then
    bad "no mirror-side skopeo verification call recorded"
    cat "$SKOPEO_ARGS" | sed 's/^/    /'
else
    # 1. flat --cert-dir layout — asserted at call time by the mock above
    verdict="$(cat "${SKOPEO_CERTDIR_VERDICT}" 2>/dev/null || true)"
    if [[ "$verdict" == *"layout=FLAT content=MATCH" ]]; then
        ok "--cert-dir <dir> contains ca.crt directly (flat layout) with the configured CA content"
    else
        bad "--cert-dir layout wrong at call time: ${verdict:-no verification call}"
    fi
    # and the temp dir is cleaned up once the step finishes
    certdir_path="$(sed 's/^certdir=//; s/ layout=.*//' <<< "$verdict")"
    if [[ -n "$certdir_path" && ! -e "$certdir_path" ]]; then
        ok "temporary cert dir removed after the step"
    else
        bad "temporary cert dir leaked: ${certdir_path}"
    fi

    # 2. explicit TLS verification with a CA configured
    if grep -q -- "--tls-verify=true" <<< "$verify_line" \
        && ! grep -q -- "--tls-verify=false" <<< "$verify_line"; then
        ok "--tls-verify=true explicitly set with a CA configured (no silent insecure fallback)"
    else
        bad "TLS flags wrong: $verify_line"
    fi

    # 3. auth via --authfile only, never --creds
    if grep -q -- "--authfile ${HOME}/pull-secret.json" <<< "$verify_line" \
        && ! grep -q -- "--creds" <<< "$verify_line"; then
        ok "credentials via --authfile only (--creds absent from argv)"
    else
        bad "auth flags wrong: $verify_line"
    fi

    # 4. the verification targeted the mirror, not the source
    if grep -q "docker://${MIRROR_REGISTRY}/validatedpatterns/pattern-install" <<< "$verify_line"; then
        ok "verification targets the mirror destination"
    else
        bad "verification target wrong: $verify_line"
    fi
fi

echo
echo "mirror-verify tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
