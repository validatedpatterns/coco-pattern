#!/usr/bin/env bash
# Tests for scripts/airgap-post-install.sh --prereq-only (B-2 prerequisite).
#
# Runs the real script against a mocked `oc` so every failure mode is
# exercised without a cluster:
#   - argument typos / extra args  → exit 2, no cluster I/O at all
#   - wrong target (4.x, non-OVN)  → exit 1, nothing patched
#   - already enabled              → exit 0, nothing patched (idempotent)
#   - read failure                 → exit 1, nothing patched (fail closed)
#   - write failure                → exit 1, patch attempted once
#   - happy path                   → exit 0, patched exactly once
#   - no git/python3/MIRROR_REGISTRY dependency in prereq mode
#
# Usage: bash tests/test-airgap-post-install-prereq.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${PATTERN_DIR}/scripts/airgap-post-install.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { echo "PASS: $*"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

# ── The oc mock ─────────────────────────────────────────────────────
# Behaviour is driven by env vars / files under $WORK:
#   OC_VERSION       cluster version reported by clusterversion (default 5.0.2)
#   OC_NETWORK_TYPE  networkType (default OVNKubernetes)
#   OC_STATE         routingViaHost state: "true", "false" or "unset"
#                    (absent from the JSON) — see network.operator JSON
#   OC_FAIL_GET      when set, ALL oc get commands fail (API outage)
#   OC_FAIL_PATCH    when set, oc patch fails
#   OC_CALLS         file accumulating every oc invocation (one per line)
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/oc" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "${OC_CALLS:?}"
case "$*" in
    "whoami")
        echo "kube:admin"; exit 0 ;;
    "get clusterversion version -o jsonpath={.status.desired.version}")
        [[ -n "${OC_FAIL_GET:-}" ]] && exit 1
        echo "${OC_VERSION:-5.0.2}"; exit 0 ;;
    "get network.operator cluster -o jsonpath={.spec.defaultNetwork.networkType}")
        [[ -n "${OC_FAIL_GET:-}" ]] && exit 1
        echo "${OC_NETWORK_TYPE:-OVNKubernetes}"; exit 0 ;;
    "get infrastructure cluster -o jsonpath={.status.platform}")
        [[ -n "${OC_FAIL_GET:-}" ]] && exit 1
        echo "BareMetal"; exit 0 ;;
    "get network.operator cluster -o json")
        [[ -n "${OC_FAIL_GET:-}" ]] && exit 1
        if [[ "${OC_STATE:-unset}" == "unset" ]]; then
            # field absent: oc -o jsonpath would error, -o json succeeds
            echo '{"apiVersion":"operator.openshift.io/v1","kind":"Network"}'
        else
            printf '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":%s}}}}}' \
                "${OC_STATE}"
        fi
        exit 0 ;;
    "patch network.operator cluster --type merge -p "*)
        [[ -n "${OC_FAIL_PATCH:-}" ]] && { echo "Error from server: mock patch failure" >&2; exit 1; }
        echo "network.operator.config/cluster patched"; exit 0 ;;
    *)
        echo "oc mock: unhandled: $*" >&2; exit 64 ;;
esac
MOCK
chmod +x "${WORK}/bin/oc"

export PATH="${WORK}/bin:$PATH"
export OC_CALLS="${WORK}/calls"
export OC_VERSION OC_NETWORK_TYPE OC_STATE OC_FAIL_GET OC_FAIL_PATCH
export KUBECONFIG="${WORK}/kubeconfig"
: > "$KUBECONFIG"

run_script() { # runs the script; rc in RC, stdout in $OUT, stderr in $ERR
    OUT="$WORK/out" ERR="$WORK/err"
    if "$SCRIPT" "$@" >"$OUT" 2>"$ERR"; then
        RC=0
    else
        RC=$?
    fi
}

patch_calls() { awk '/patch network.operator/{n++} END{print n+0}' "$OC_CALLS" 2>/dev/null; }
any_oc_calls() { [[ -s "$OC_CALLS" ]] && echo yes || echo no; }

# ── 1. Typo'd flag → exit 2, zero cluster I/O ───────────────────────
: > "$OC_CALLS"
run_script --prereq-onyl
if [[ "$RC" == "2" && "$(any_oc_calls)" == "no" ]] \
    && grep -q "Unknown argument: '--prereq-onyl'" "$ERR"; then
    ok "typo'd flag (--prereq-onyl): exit 2, no oc call, usage shown"
else
    bad "typo'd flag (--prereq-onyl): RC=$RC oc_calls=$(any_oc_calls)"
    sed 's/^/    /' "$ERR" | head -5
fi

# ── 2. Extra argument after the flag → exit 2, zero cluster I/O ────
: > "$OC_CALLS"
run_script --prereq-only extra
if [[ "$RC" == "2" && "$(any_oc_calls)" == "no" ]] \
    && grep -q "Unexpected argument" "$ERR"; then
    ok "extra argument after flag: exit 2, no oc call"
else
    bad "extra argument after flag: RC=$RC oc_calls=$(any_oc_calls)"
fi

# ── 3. Garbage first argument (old silent fall-through) → exit 2 ───
: > "$OC_CALLS"
run_script --frobnicate
if [[ "$RC" == "2" && "$(any_oc_calls)" == "no" ]]; then
    ok "unknown flag (--frobnicate): exit 2, no oc call (no full-bootstrap fall-through)"
else
    bad "unknown flag (--frobnicate): RC=$RC oc_calls=$(any_oc_calls)"
fi

# ── 4. Wrong target: 4.22 cluster → exit 1, nothing patched ────────
: > "$OC_CALLS"
OC_VERSION=4.22.17
run_script --prereq-only
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "targets OpenShift 5.x, this cluster runs 4.22.17" "$ERR"; then
    ok "wrong target (4.22): exit 1, no patch, no full-bootstrap side effects"
else
    bad "wrong target (4.22): RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$ERR" | head -5
fi
OC_VERSION=5.0.2

# ── 5. Wrong target: non-OVN network → exit 1, nothing patched ─────
: > "$OC_CALLS"
OC_NETWORK_TYPE=OpenShiftSDN
run_script --prereq-only
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "OVN-Kubernetes knob" "$ERR"; then
    ok "wrong target (OpenShiftSDN): exit 1, no patch"
else
    bad "wrong target (OpenShiftSDN): RC=$RC patches=$(patch_calls)"
fi
OC_NETWORK_TYPE=OVNKubernetes

# ── 6. Already enabled → exit 0, nothing patched (idempotent) ──────
: > "$OC_CALLS"
OC_STATE=true
run_script --prereq-only
if [[ "$RC" == "0" && "$(patch_calls)" == "0" ]] \
    && grep -q "already true — no change (idempotent)" "$OUT" \
    && grep -q "Prerequisite satisfied: routingViaHost=true" "$OUT"; then
    ok "already enabled: exit 0, no patch, reports satisfied"
else
    bad "already enabled: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$OUT" | head -8
fi

# ── 7. Read failure → exit 1, nothing patched ──────────────────────
: > "$OC_CALLS"
OC_STATE=false OC_FAIL_GET=1
run_script --prereq-only
if [[ "$RC" == "1" && "$(patch_calls)" == "0" ]] \
    && grep -q "Cannot read" "$ERR"; then
    ok "read failure: exit 1, no patch (failed read ≠ unset)"
else
    bad "read failure: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$ERR" | head -5
fi
OC_FAIL_GET=""

# ── 8. Write failure → exit 1, patch attempted exactly once ────────
: > "$OC_CALLS"
OC_STATE=false OC_FAIL_PATCH=1
run_script --prereq-only
if [[ "$RC" == "1" && "$(patch_calls)" == "1" ]] \
    && grep -q "oc patch network.operator failed" "$ERR"; then
    ok "write failure: exit 1, one patch attempt, error propagated"
else
    bad "write failure: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$ERR" | head -5
fi
OC_FAIL_PATCH=""

# ── 9. Happy path: unset → patched once, end state verified ────────
: > "$OC_CALLS"
OC_STATE=true   # the mock reports true AFTER a successful patch
# emulate: pre-patch state unset; post-patch true. The script reads twice —
# serve "unset" first, then "true".
cat > "${WORK}/bin/oc" <<'MOCK2'
#!/usr/bin/env bash
echo "$*" >> "${OC_CALLS:?}"
READS="${OC_CALLS}.reads"
case "$*" in
    "whoami") echo "kube:admin"; exit 0 ;;
    "get clusterversion version -o jsonpath={.status.desired.version}") echo "5.0.2"; exit 0 ;;
    "get network.operator cluster -o jsonpath={.spec.defaultNetwork.networkType}") echo "OVNKubernetes"; exit 0 ;;
    "get infrastructure cluster -o jsonpath={.status.platform}") echo "BareMetal"; exit 0 ;;
    "get network.operator cluster -o json")
        n=$(grep -c "get network.operator cluster -o json" "$READS" 2>/dev/null || echo 0)
        echo "$*" >> "$READS"
        if [[ "$n" -eq 0 ]]; then
            # first read: field absent (fresh cluster)
            echo '{"apiVersion":"operator.openshift.io/v1","kind":"Network"}'
        else
            # after the patch: true
            echo '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
        fi
        exit 0 ;;
    "patch network.operator cluster --type merge -p "*)
        echo "network.operator.config/cluster patched"; exit 0 ;;
    *) echo "oc mock: unhandled: $*" >&2; exit 64 ;;
esac
MOCK2
chmod +x "${WORK}/bin/oc"
rm -f "${OC_CALLS}.reads"
run_script --prereq-only
if [[ "$RC" == "0" && "$(patch_calls)" == "1" ]] \
    && grep -q "Prerequisite satisfied: routingViaHost=true" "$OUT" \
    && grep -q "Next: openshift-install agent wait-for install-complete" "$OUT"; then
    ok "happy path: patch once, verified end state, exit 0 with next-step guidance"
else
    bad "happy path: RC=$RC patches=$(patch_calls)"
    sed 's/^/    /' "$OUT" | head -10; sed 's/^/    /' "$ERR" | head -5
fi

# ── 10. Prereq mode needs neither git, python3, nor MIRROR_REGISTRY ─
# Shadow git/python3 with failing stubs and leave MIRROR_REGISTRY unset.
mkdir -p "${WORK}/nopath"
for cmd in git python3; do
    printf '#!/usr/bin/env bash\necho "%s: blocked by test" >&2\nexit 127\n' "$cmd" \
        > "${WORK}/nopath/$cmd"
    chmod +x "${WORK}/nopath/$cmd"
done
cat > "${WORK}/nopath/oc" <<'MOCK3'
#!/usr/bin/env bash
echo "$*" >> "${OC_CALLS:?}"
case "$*" in
    "whoami") echo "kube:admin"; exit 0 ;;
    "get clusterversion version -o jsonpath={.status.desired.version}") echo "5.0.2"; exit 0 ;;
    "get network.operator cluster -o jsonpath={.spec.defaultNetwork.networkType}") echo "OVNKubernetes"; exit 0 ;;
    "get infrastructure cluster -o jsonpath={.status.platform}") echo "BareMetal"; exit 0 ;;
    "get network.operator cluster -o json")
        echo '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'; exit 0 ;;
    "patch network.operator cluster --type merge -p "*)
        echo "network.operator.config/cluster patched"; exit 0 ;;
    *) echo "oc mock: unhandled: $*" >&2; exit 64 ;;
esac
MOCK3
chmod +x "${WORK}/nopath/oc"
: > "$OC_CALLS"
OUT="$WORK/out" ERR="$WORK/err"
env -i PATH="${WORK}/nopath:/usr/bin:/bin" HOME="$HOME" KUBECONFIG="$KUBECONFIG" \
    OC_CALLS="$OC_CALLS" "$SCRIPT" --prereq-only >"$OUT" 2>"$ERR"
rc=$?
if [[ $rc -eq 0 ]] && ! grep -qE "blocked by test|Missing required" "$OUT" "$ERR"; then
    ok "no git/python3/MIRROR_REGISTRY dependency: exit 0 with shadowed tooling"
else
    bad "dependency leak: RC=$RC"
    sed 's/^/    /' "$OUT" "$ERR" 2>/dev/null | head -8
fi

echo
echo "prereq-only tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
