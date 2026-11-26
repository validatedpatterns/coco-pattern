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
        authfile=""
        prev=""
        for a in "$@"; do
            [[ "$prev" == "--cert-dir" ]] && certdir="$a"
            [[ "$prev" == "--authfile" ]] && authfile="$a"
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
        # Record the authfile AT CALL TIME (path, mode, content): the
        # script removes a generated one when the step finishes.
        {
            printf 'path=%s\n' "$authfile"
            printf 'mode=%s\n' "$(stat -c %a "$authfile" 2>/dev/null || echo MISSING)"
            printf 'content=%s\n' "$(cat "$authfile" 2>/dev/null)"
        } >> "${SKOPEO_AUTHFILE_INSPECT:?}"
        echo '{"Tags":["0.0.19","0.0.20"]}'; exit 0 ;;
    *) echo "skopeo mock: unhandled: $*" >&2; exit 64 ;;
esac
MOCK
chmod +x "${WORK}/bin/oc" "${WORK}/bin/skopeo"
export PATH="${WORK}/bin:$PATH"
export SKOPEO_ARGS="${WORK}/skopeo-args"
export SKOPEO_CERTDIR_VERDICT="${WORK}/certdir-verdict"
export SKOPEO_AUTHFILE_INSPECT="${WORK}/authfile-inspect"
export TEST_CA="${WORK}/ca.pem"

# ── Run the step (once per credential source) ────────────────────────
export MIRROR_REGISTRY="quay.example.com:443/mirror"
RC=0 OUT="" ERR=""
run_step() { # $1 = tag; $2 = "strict" to model the script's own set -euo pipefail
    local tag="$1" mode="${2:-}"
    OUT="${WORK}/out-${tag}" ERR="${WORK}/err-${tag}"
    : > "$SKOPEO_CERTDIR_VERDICT"
    : > "$SKOPEO_ARGS"
    : > "$SKOPEO_AUTHFILE_INSPECT"
    (
        export PATH MIRROR_REGISTRY SKOPEO_ARGS PATTERN_DIR SKOPEO_AUTHFILE_INSPECT
        export MIRROR_USER="${MIRROR_USER:-}" MIRROR_PASS="${MIRROR_PASS:-}" \
               SKOPEO_AUTHFILE="${SKOPEO_AUTHFILE:-}" \
               MIRROR_CA_FILE="${MIRROR_CA_FILE:-}"
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
        # The real script runs under `set -euo pipefail`; Case C needs that
        # to reproduce the abort path faithfully.
        [[ "$mode" == "strict" ]] && set -euo pipefail
        # shellcheck disable=SC1090
        source "${WORK}/func.sh"
        mirror_oci_charts
    ) >"$OUT" 2>"$ERR"
    # NOT `if ( … ); then`: bash ignores `set -e` for a command in an
    # `if` condition, and the ignoring propagates into the subshell even
    # though it re-enables -e itself — the abort path would not reproduce.
    RC=$?
}

# Case A: default pull-secret authfile (SKOPEO_AUTHFILE and the
# MIRROR_USER/MIRROR_PASS pair both unset).
MIRROR_USER="" MIRROR_PASS="" SKOPEO_AUTHFILE=""
run_step pull-secret
rc="$RC"

# ── Assertions on the recorded skopeo argv ───────────────────────────
verify_line="$(grep 'list-tags --authfile' "$SKOPEO_ARGS" | head -1)"

if [[ $rc -ne 0 ]]; then
    bad "mirror_oci_charts exited $rc"
    sed 's/^/    /' "$ERR" | head -8
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

# ── Case B: MIRROR_USER/MIRROR_PASS → temporary 0600 authfile ────────
# SKOPEO_AUTHFILE points elsewhere here, so precedence is asserted too.
MIRROR_USER="robot\$mirror+coco" MIRROR_PASS="p4ss w0rd!" \
    SKOPEO_AUTHFILE="${WORK}/bogus-authfile.json"
cat > "${SKOPEO_AUTHFILE}" <<'EOF'
{"auths":{"quay.example.com:443":{"auth":"Ym9ndXM6Ym9ndXM="}}}
EOF
run_step mirror-robot
rc="$RC"
verify_line="$(grep 'list-tags --authfile' "$SKOPEO_ARGS" | head -1)"
inspect_path="$(sed -n 's/^path=//p' "$SKOPEO_AUTHFILE_INSPECT" | head -1)"
inspect_mode="$(sed -n 's/^mode=//p' "$SKOPEO_AUTHFILE_INSPECT" | head -1)"
inspect_content="$(sed -n 's/^content=//p' "$SKOPEO_AUTHFILE_INSPECT" | head -1)"

expected_auth="$(MIRROR_USER="$MIRROR_USER" MIRROR_PASS="$MIRROR_PASS" python3 -c '
import base64, json, os
token = base64.b64encode(
    (os.environ["MIRROR_USER"] + ":" + os.environ["MIRROR_PASS"]).encode()).decode()
print(json.dumps({"auths": {"quay.example.com:443": {"auth": token}}}, sort_keys=True))')"

if [[ $rc -ne 0 ]]; then
    bad "MIRROR_USER/MIRROR_PASS run exited $rc"
    sed 's/^/    /' "$ERR" | head -8
elif [[ -z "$verify_line" ]]; then
    bad "MIRROR_USER/MIRROR_PASS: no mirror-side skopeo verification call"
    sed 's/^/    /' "$SKOPEO_ARGS"
else
    # 5. the documented pair produced the authfile actually passed to skopeo
    if [[ -n "$inspect_path" && "$inspect_path" != "${HOME}/pull-secret.json" \
        && "$inspect_path" != "${SKOPEO_AUTHFILE}" ]] \
        && grep -q -- "--authfile ${inspect_path}" <<< "$verify_line"; then
        ok "MIRROR_USER/MIRROR_PASS generate a temp authfile that takes precedence over SKOPEO_AUTHFILE"
    else
        bad "temp authfile not used: path='${inspect_path}' argv=${verify_line}"
    fi
    # 6. its content is exactly {"auths":{"<registry host>":{"auth":<b64 user:pass>}}}
    if [[ -n "$inspect_content" ]] \
        && [[ "$(printf '%s' "$inspect_content" | python3 -c '
import json, sys
print(json.dumps(json.load(sys.stdin), sort_keys=True))' 2>/dev/null)" == "$expected_auth" ]]; then
        ok "temp authfile content = base64(MIRROR_USER:MIRROR_PASS) keyed by the registry host"
    else
        bad "temp authfile content wrong: '${inspect_content}' (expected '${expected_auth}')"
    fi
    # 7. 0600 at call time, and the password never reaches argv
    if [[ "$inspect_mode" == "600" ]] && ! grep -q -- "--creds" <<< "$verify_line" \
        && ! grep -qF "$MIRROR_PASS" <<< "$verify_line"; then
        ok "temp authfile is 0600 at call time; no password or --creds on argv"
    else
        bad "authfile mode/password leak: mode='${inspect_mode}' argv=${verify_line}"
    fi
    # 8. removed after the step (only the caller-supplied file survives)
    if [[ -n "$inspect_path" && ! -e "$inspect_path" ]] && [[ -f "${SKOPEO_AUTHFILE}" ]]; then
        ok "temporary authfile removed after the step"
    else
        bad "temporary authfile leaked: '${inspect_path}'"
    fi
fi

# ── Case C: failure BETWEEN authfile creation and the verification call ─
# The 0600 authfile holding base64(MIRROR_USER:MIRROR_PASS) is created
# before the mirror CA is used. A MIRROR_CA_FILE that does not exist makes
# the cert-dir `cp` fail, which under `set -e` aborts the step *there* —
# after the credential file exists, before skopeo runs. The credential file
# must not survive that exit.
CA_FAIL_USER='robot$mirror+coco'
CA_FAIL_PASS='p4ss w0rd!'
export TMPDIR="${WORK}/tmp-ca-fail"     # private temp dir — the only place
mkdir -p "$TMPDIR"                      # the authfile may be created
export MIRROR_CA_FILE="${WORK}/this-ca-does-not-exist.pem"
MIRROR_USER="$CA_FAIL_USER" MIRROR_PASS="$CA_FAIL_PASS" SKOPEO_AUTHFILE="" \
    run_step ca-missing strict
rc="$RC"
unset MIRROR_CA_FILE

if [[ $rc -eq 0 ]]; then
    bad "missing MIRROR_CA_FILE did not abort the step (rc=0)"
    sed 's/^/    /' "$OUT" | head -5
else
    ok "step aborts (rc=${rc}) when MIRROR_CA_FILE is missing — mid-step failure reproduced"
fi

# 9. nothing created so far survives the abort
leftovers="$(find "$TMPDIR" -mindepth 1 2>/dev/null | sort || true)"
if [[ -z "$leftovers" ]]; then
    ok "no temp artefact survives the mid-step failure"
else
    bad "temp artefacts leaked after the mid-step failure: $(tr '\n' ' ' <<< "$leftovers")"
fi

# 10. and the mirror robot credential is nowhere on disk under the temp dir
ca_fail_token="$(CA_FAIL_USER="$CA_FAIL_USER" CA_FAIL_PASS="$CA_FAIL_PASS" python3 -c '
import base64, os
print(base64.b64encode(
    (os.environ["CA_FAIL_USER"] + ":" + os.environ["CA_FAIL_PASS"]).encode()).decode())')"
leaked=""
while IFS= read -r f; do
    [[ -z "$f" || ! -f "$f" ]] && continue
    if grep -qF "$ca_fail_token" "$f" 2>/dev/null || grep -qF "$CA_FAIL_PASS" "$f" 2>/dev/null; then
        leaked="$f"
    fi
done <<< "$leftovers"
if [[ -z "$leaked" ]]; then
    ok "credential content absent from every leftover temp file"
else
    bad "credential leaked in leftover temp file: ${leaked}"
fi

echo
echo "mirror-verify tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
