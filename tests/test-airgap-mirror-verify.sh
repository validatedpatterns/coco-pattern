#!/usr/bin/env bash
# Unit test for the skopeo invocation in mirror_oci_charts (step 5 of
# scripts/airgap-post-install.sh): runs the sed-extracted function
# against mocked oc/skopeo (argv recorded at call time).
#
# SCOPE — only the dangerous behaviours, three runs:
#   A. happy path, default pull-secret: --authfile (never --creds),
#      --tls-verify=true with a CA configured, target = the mirror,
#      --cert-dir flat (ca.crt directly inside) and holding the SAME CA
#      as configured (cmp -s — presence alone passes a wrong-cert bug),
#      temp cert dir cleaned up after the step
#   B. MIRROR_USER/MIRROR_PASS: temporary 0600 authfile taking
#      precedence, correct credential content, password never on argv,
#      file removed after the step
#   C. failure BETWEEN authfile creation and the verification call:
#      no credential-bearing artefact survives the abort
# The retired assertions (SKOPEO_AUTHFILE precedence matrices, argv flag
# permutations) re-encoded our own assumptions rather than observable
# behaviour.
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

# ── Mocked oc (image mirror no-ops) and skopeo (records at call time) ─
# The skopeo mock records the argv and, for the mirror-side call only,
# the authfile (path/mode/content) and the cert dir (path + flat-layout
# verdict) AS THE CALL HAPPENS — the script deletes both afterwards.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/oc" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    "image mirror "*) exit 0 ;;
    *) echo "oc mock: unhandled: $*" >&2; exit 64 ;;
esac
MOCK
cat > "${WORK}/bin/skopeo" <<'MOOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SKOPEO_ARGS:?}"
case "$*" in
    "list-tags docker://quay.io/validatedpatterns/pattern-install")
        echo '{"Tags":["0.0.19","0.0.20"]}'; exit 0 ;;
    "list-tags --authfile "*" --cert-dir "*" --tls-verify=true docker://"*)
        certdir="" authfile="" prev=""
        for a in "$@"; do
            [[ "$prev" == "--cert-dir" ]] && certdir="$a"
            [[ "$prev" == "--authfile" ]] && authfile="$a"
            prev="$a"
        done
        # Flat layout: containers/image wants ca.crt directly in --cert-dir,
        # and it must be the CONFIGURED CA — presence alone would pass with
        # the wrong certificate copied in.
        if [[ -f "${certdir}/ca.crt" ]] && cmp -s "${certdir}/ca.crt" "${TEST_CA:?}"; then
            layout=FLAT
        else
            layout=WRONG
        fi
        printf 'certdir=%s layout=%s\n' "$certdir" "$layout" >> "${SKOPEO_CERTDIR:?}"
        printf 'path=%s\nmode=%s\ncontent=%s\n' "$authfile" \
            "$(stat -c %a "$authfile" 2>/dev/null || echo MISSING)" \
            "$(cat "$authfile" 2>/dev/null)" >> "${SKOPEO_AUTHFILE_INSPECT:?}"
        echo '{"Tags":["0.0.19","0.0.20"]}'; exit 0 ;;
    *) echo "skopeo mock: unhandled: $*" >&2; exit 64 ;;
esac
MOOCK
chmod +x "${WORK}/bin/oc" "${WORK}/bin/skopeo"
export PATH="${WORK}/bin:$PATH"
export SKOPEO_ARGS="${WORK}/skopeo-args"
export SKOPEO_CERTDIR="${WORK}/certdir"
export TEST_CA="${WORK}/ca.pem"   # compared against the copied ca.crt at call time
export SKOPEO_AUTHFILE_INSPECT="${WORK}/authfile-inspect"

# ── Run the step ─────────────────────────────────────────────────────
export MIRROR_REGISTRY="quay.example.com:443/mirror"
RC=0 OUT="" ERR=""
run_step() { # $1 = tag; $2 = "strict" to model the script's own set -euo pipefail
    local tag="$1" mode="${2:-}"
    OUT="${WORK}/out-${tag}" ERR="${WORK}/err-${tag}"
    : > "$SKOPEO_ARGS"; : > "$SKOPEO_CERTDIR"; : > "$SKOPEO_AUTHFILE_INSPECT"
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

verify_line() { grep 'list-tags --authfile' "$SKOPEO_ARGS" | head -1; }

# ── Case A: default pull-secret authfile (happy path) ────────────────
MIRROR_USER="" MIRROR_PASS="" SKOPEO_AUTHFILE=""
run_step pull-secret
rc="$RC"
line="$(verify_line)"
if [[ $rc -ne 0 ]]; then
    bad "mirror_oci_charts exited $rc"
    sed 's/^/    /' "$ERR" | head -8
elif [[ -z "$line" ]]; then
    bad "no mirror-side skopeo verification call recorded"
    sed 's/^/    /' "$SKOPEO_ARGS"
else
    if grep -q -- "--tls-verify=true" <<< "$line" \
        && ! grep -q -- "--tls-verify=false" <<< "$line"; then
        ok "happy path: --tls-verify=true explicitly set with a CA configured"
    else
        bad "TLS flags wrong: $line"
    fi
    if grep -q -- "--authfile ${HOME}/pull-secret.json" <<< "$line" \
        && ! grep -q -- "--creds" <<< "$line"; then
        ok "happy path: credentials via --authfile only (--creds absent from argv)"
    else
        bad "auth flags wrong: $line"
    fi
    if grep -q "docker://${MIRROR_REGISTRY}/validatedpatterns/pattern-install" <<< "$line"; then
        ok "happy path: verification targets the mirror destination"
    else
        bad "verification target wrong: $line"
    fi
    certdir_line="$(cat "$SKOPEO_CERTDIR" 2>/dev/null || true)"
    certdir_path="$(sed 's/^certdir=//; s/ layout=.*//' <<< "$certdir_line")"
    if [[ "$certdir_line" == *"layout=FLAT" && -n "$certdir_path" && ! -e "$certdir_path" ]]; then
        ok "happy path: flat --cert-dir holding the configured CA (cmp -s), removed after the step"
    else
        bad "cert dir wrong or leaked: ${certdir_line:-no verification call}"
    fi
fi

# ── Case B: MIRROR_USER/MIRROR_PASS → temporary 0600 authfile ────────
MIRROR_USER="robot\$mirror+coco" MIRROR_PASS="p4ss w0rd!" \
    SKOPEO_AUTHFILE="${WORK}/bogus-authfile.json"
cat > "${SKOPEO_AUTHFILE}" <<'EOF'
{"auths":{"quay.example.com:443":{"auth":"Ym9ndXM6Ym9ndXM="}}}
EOF
run_step mirror-robot
rc="$RC"
line="$(verify_line)"
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
elif [[ -z "$line" ]]; then
    bad "MIRROR_USER/MIRROR_PASS: no mirror-side skopeo verification call"
    sed 's/^/    /' "$SKOPEO_ARGS"
else
    if [[ -n "$inspect_path" && "$inspect_path" != "${HOME}/pull-secret.json" \
        && "$inspect_path" != "${SKOPEO_AUTHFILE}" ]] \
        && grep -q -- "--authfile ${inspect_path}" <<< "$line"; then
        ok "MIRROR_USER/MIRROR_PASS: temp authfile used (precedence over SKOPEO_AUTHFILE)"
    else
        bad "temp authfile not used: path='${inspect_path}' argv=${line}"
    fi
    if [[ "$inspect_mode" == "600" ]] && ! grep -q -- "--creds" <<< "$line" \
        && ! grep -qF "$MIRROR_PASS" <<< "$line"; then
        ok "temp authfile is 0600 at call time; no password or --creds on argv"
    else
        bad "authfile mode/password leak: mode='${inspect_mode}' argv=${line}"
    fi
    if [[ "$(printf '%s' "$inspect_content" | python3 -c '
import json, sys
print(json.dumps(json.load(sys.stdin), sort_keys=True))' 2>/dev/null)" == "$expected_auth" ]]; then
        ok "temp authfile content = base64(MIRROR_USER:MIRROR_PASS) keyed by the registry host"
    else
        bad "temp authfile content wrong: '${inspect_content}' (expected '${expected_auth}')"
    fi
    if [[ -n "$inspect_path" && ! -e "$inspect_path" ]] && [[ -f "${SKOPEO_AUTHFILE}" ]]; then
        ok "temp authfile removed after the step"
    else
        bad "temp authfile leaked: '${inspect_path}'"
    fi
fi

# ── Case C: failure BETWEEN authfile creation and the verification ───
# A MIRROR_CA_FILE that does not exist makes the cert-dir `cp` fail,
# which under `set -e` aborts the step there — after the credential file
# exists, before skopeo runs. The credential file must not survive.
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

leftovers="$(find "$TMPDIR" -mindepth 1 2>/dev/null | sort || true)"
if [[ -z "$leftovers" ]]; then
    ok "no temp artefact survives the mid-step failure"
else
    bad "temp artefacts leaked after the mid-step failure: $(tr '\n' ' ' <<< "$leftovers")"
fi

# The mirror robot credential is nowhere on disk under the temp dir.
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
