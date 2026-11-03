#!/usr/bin/env bash
# Render gate for the CoCo pattern values chain — both connectivity modes.
#
# Reproduces, without a cluster, the exact values chain the patterns-operator
# assembles for the ROOT clustergroup Application (values-global.yaml +
# values-<group>.yaml + the sharedValueFiles it resolves for the platform/
# storage/version/hardware/airgap axes), then asserts:
#
#   airgap mode
#     - intel subscriptions render on the mirrored certified catalog
#     - sourceless subscriptions render on the mirrored redhat catalog
#     - the acm mce_operator override renders the mirrored catalog
#     - the trustee collateral override renders the file:// backend
#   connected mode
#     - intel subscriptions stay on certified-operators
#     - sourceless subscriptions stay on redhat-operators (chart default)
#     - the acm mce_operator override renders redhat-operators (chart default)
#     - the trustee collateral override renders the Intel PCS URL
#   workload charts (each, standalone)
#     - connected: upstream registry.redhat.io images unchanged
#     - airgap: images rewritten against global.mirrorRegistry
#     - airgap without a mirror: rendering FAILS (fail-fast, not a silent
#       ImagePullBackOff in the CVM)
#
# Usage: scripts/verify/render-gate.sh [mirror-root]
#   mirror-root defaults to quay.example:443/mirror (placeholder is fine —
#   nothing is pulled; only the rendered strings are asserted).
#
# Requires: helm >= 3.14 and network access to quay.io for the chart pull.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CLUSTERGROUP_VERSION="0.9.58"
GROUP="baremetal"
PLATFORM="None"                 # SNO: no values-<platform> file is present
MIRROR_ROOT="${1:-quay.example:443/mirror}"
FAILS=0

pass() { echo -e "PASS: $*"; }
fail() { echo -e "FAIL: $*"; FAILS=$((FAILS + 1)); }

# ── Root render: the operator's value chain ──────────────────────────
helm pull oci://quay.io/validatedpatterns/clustergroup \
    --version "$CLUSTERGROUP_VERSION" --untar --untardir "$WORK" >/dev/null
CHART="${WORK}/clustergroup"

render_root() { # $1 = airgap|connected
    local mode="$1"
    helm template cg "${CHART}" \
        -f "${PATTERN_DIR}/values-global.yaml" \
        -f "${PATTERN_DIR}/values-${GROUP}.yaml" \
        -f "${PATTERN_DIR}/overrides/values-storage-lvm.yaml" \
        -f "${PATTERN_DIR}/overrides/values-4.22.yaml" \
        -f "${PATTERN_DIR}/overrides/values-hw-intel-tdx.yaml" \
        -f "${PATTERN_DIR}/overrides/values-${GROUP}-${mode}.yaml" \
        --set global.repoURL=https://example.com/coco-pattern.git \
        --set global.targetRevision=render-gate \
        --set global.airgap="$([ "$mode" = airgap ] && echo true || echo false)" \
        --set-string "global.mirrorRegistry=$([ "$mode" = airgap ] && echo "$MIRROR_ROOT" || echo '')" \
        2>/dev/null
}

sub_source() { # $1 = rendered manifest, $2 = subscription name
    echo "$1" | awk -v wanted="$2" '
        /^  name: / { cur = $2 }
        /^  source: / { if (cur == wanted) { print $2; exit } }'
}

acm_override() { # $1 = rendered manifest
    echo "$1" | grep -A1 'name: acm.mce_operator.source' | grep 'value:' | head -1 | sed "s/.*value: //; s/'//g; s/\"//g"
}

collateral_override() { # $1 = rendered manifest
    echo "$1" | grep -A1 'name: kbs.tdx.collateralService' | grep 'value:' | head -1 | sed "s/.*value: //; s/'//g; s/\"//g"
}

# ── Airgap assertions ────────────────────────────────────────────────
echo "── airgap mode (global.airgap=true, mirror=${MIRROR_ROOT})"
AIRGAP="$(render_root airgap)" || { fail "airgap root render errored"; }

for sub in intel-device-plugins-operator intel-tdx-dcap-operator; do
    src="$(sub_source "$AIRGAP" "$sub")"
    [[ "$src" == "cs-certified-operator-index-v4-22" ]] \
        && pass "subscription $sub → $src" \
        || fail "subscription $sub → '${src}' (expected cs-certified-operator-index-v4-22)"
done

for sub in openshift-external-secrets-operator trustee-operator sandboxed-containers-operator; do
    src="$(sub_source "$AIRGAP" "$sub")"
    [[ "$src" == "cs-redhat-operator-index-v4-22" ]] \
        && pass "subscription $sub → $src" \
        || fail "subscription $sub → '${src}' (expected cs-redhat-operator-index-v4-22)"
done

val="$(acm_override "$AIRGAP")"
[[ "$val" == "cs-redhat-operator-index-v4-22" ]] \
    && pass "acm.mce_operator.source → $val" \
    || fail "acm.mce_operator.source → '${val}' (expected cs-redhat-operator-index-v4-22)"

val="$(collateral_override "$AIRGAP")"
[[ "$val" == file:///opt/confidential-containers/attestation-service/tdx/platform_collaterals.json ]] \
    && pass "kbs.tdx.collateralService → file:// backend" \
    || fail "kbs.tdx.collateralService → '${val}' (expected the file:// backend)"

# ── Connected assertions ─────────────────────────────────────────────
echo "── connected mode (global.airgap=false)"
CONNECTED="$(render_root connected)" || { fail "connected root render errored"; }

for sub in intel-device-plugins-operator intel-tdx-dcap-operator; do
    src="$(sub_source "$CONNECTED" "$sub")"
    [[ "$src" == "certified-operators" ]] \
        && pass "subscription $sub → $src" \
        || fail "subscription $sub → '${src}' (expected certified-operators)"
done

for sub in openshift-external-secrets-operator trustee-operator sandboxed-containers-operator; do
    src="$(sub_source "$CONNECTED" "$sub")"
    [[ "$src" == "redhat-operators" ]] \
        && pass "subscription $sub → $src" \
        || fail "subscription $sub → '${src}' (expected redhat-operators)"
done

val="$(acm_override "$CONNECTED")"
[[ "$val" == "redhat-operators" ]] \
    && pass "acm.mce_operator.source → $val (chart default)" \
    || fail "acm.mce_operator.source → '${val}' (expected redhat-operators)"

val="$(collateral_override "$CONNECTED")"
[[ "$val" == "https://api.trustedservices.intel.com/sgx/certification/v4/" ]] \
    && pass "kbs.tdx.collateralService → Intel PCS" \
    || fail "kbs.tdx.collateralService → '${val}' (expected Intel PCS URL)"

# ── Workload charts ──────────────────────────────────────────────────
echo "── workload charts"
for chart in hello-openshift kbs-access-curl kbs-access-sealed; do
    out="$(helm template wg "${PATTERN_DIR}/charts/coco-supported/${chart}" \
        --set global.coco.runtimeClassName=kata-cc 2>/dev/null)" \
        || { fail "$chart connected render errored"; continue; }
    if echo "$out" | grep -q "registry.redhat.io/ubi9/httpd-24@sha256:68a91ff"; then
        pass "$chart connected: upstream image unchanged"
    else
        fail "$chart connected: image not the upstream registry.redhat.io reference"
    fi

    out="$(helm template wg "${PATTERN_DIR}/charts/coco-supported/${chart}" \
        --set global.coco.runtimeClassName=kata-cc --set global.airgap=true \
        --set-string "global.mirrorRegistry=${MIRROR_ROOT}" 2>/dev/null)" \
        || { fail "$chart airgap render errored"; continue; }
    if echo "$out" | grep -q "${MIRROR_ROOT}/ubi9/httpd-24@sha256:68a91ff" \
        && ! echo "$out" | grep -q "registry.redhat.io/ubi9"; then
        pass "$chart airgap: image rewritten to ${MIRROR_ROOT}/ubi9/..."
    else
        fail "$chart airgap: image not rewritten to the mirror root"
    fi
done

# initImage (registry.access.redhat.com source path)
out="$(helm template x "${PATTERN_DIR}/charts/coco-supported/kbs-access-curl" \
    --set global.coco.runtimeClassName=kata-cc --set global.airgap=true \
    --set-string "global.mirrorRegistry=${MIRROR_ROOT}" 2>/dev/null)" \
    && echo "$out" | grep -q "${MIRROR_ROOT}/ubi9/ubi:latest" \
    && pass "kbs-access-curl airgap: initImage rewritten (registry.access path)" \
    || fail "kbs-access-curl airgap: initImage not rewritten"

# Fail-fast: airgap without a mirror must not render
if helm template x "${PATTERN_DIR}/charts/coco-supported/hello-openshift" \
        --set global.coco.runtimeClassName=kata-cc --set global.airgap=true \
        >/dev/null 2>&1; then
    fail "airgap without global.mirrorRegistry rendered (should fail fast)"
else
    pass "airgap without global.mirrorRegistry fails fast"
fi

# ── Verdict ──────────────────────────────────────────────────────────
echo ""
if [[ $FAILS -eq 0 ]]; then
    echo "RENDER GATE: PASS (0 failures)"
else
    echo "RENDER GATE: FAIL (${FAILS} failures)"
    exit 1
fi
