#!/usr/bin/env bash
# Render gate for the CoCo pattern values chain — both connectivity modes.
#
# Reproduces, without a cluster, the exact values chain the patterns-operator
# assembles for the ROOT clustergroup Application (values-global.yaml +
# values-<group>.yaml + the sharedValueFiles it resolves for the platform/
# storage/version/hardware/airgap axes), then asserts:
#
#   airgap mode (baremetal — the live-validated path)
#     - intel subscriptions render on the mirrored certified catalog
#     - sourceless subscriptions render on the mirrored redhat catalog
#     - the acm mce_operator override renders the mirrored catalog
#     - the trustee collateral override renders the file:// backend
#   connected mode
#     - intel subscriptions stay on certified-operators
#     - sourceless subscriptions stay on redhat-operators (chart default)
#     - the acm mce_operator override renders redhat-operators (chart default)
#     - the trustee collateral override renders the Intel PCS URL
#   sync-wave layout (all six cluster groups, connected mode)
#     - every gating-relevant object renders at its expected wave
#       (RBAC bridge -1, vault/secrets/kyverno 0, operator subscriptions 10,
#       acm 15, trustee/policies 20, workloads 30, vault-wait Job 5; spokes/hubs
#       assert the objects they must NOT have as ABSENT)
#   workload charts (each, standalone)
#     - connected: upstream registry.redhat.io images unchanged
#     - airgap: images rewritten against global.mirrorRegistry
#     - airgap rewrite edge cases: an image already under the mirror root
#       passes through unchanged (no double prefix); a hostless reference
#       keeps its org segment; a localhost host is stripped like any other
#     - airgap without a mirror: rendering FAILS (fail-fast, not a silent
#       ImagePullBackOff in the CVM)
#     - the three duplicated <chart>.image helpers stay byte-identical
#       modulo the define name (path-rendered charts cannot share a
#       library template, so the copies must be kept in sync manually)
#
# Usage: scripts/verify/render-gate.sh [mirror-root]
#   mirror-root defaults to quay.example:443/mirror (placeholder is fine —
#   nothing is pulled; only the rendered strings are asserted).
#
# Requires: helm >= 3.14, python3 (stdlib only); network access to quay.io
# for the chart pull — or point CLUSTERGROUP_CHART at a local (untarred)
# clustergroup chart directory to run fully offline (CI pulls, offline
# runs reuse a cached chart).
#
# NOTE on pipes: the script runs under `set -o pipefail` and greps renders
# that exceed the pipe buffer, so every consumer that can exit early
# (grep -q, awk exit, head) is fed via a here-string or an extra fd —
# never through `echo <big-render> | …`, which intermittently dies with
# SIGPIPE (141) and false-fails the gate.
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
# A local chart directory overrides the pull (offline runs); CI pulls.
if [[ -n "${CLUSTERGROUP_CHART:-}" && -d "${CLUSTERGROUP_CHART}" ]]; then
    CHART="${CLUSTERGROUP_CHART}"
else
    helm pull oci://quay.io/validatedpatterns/clustergroup \
        --version "$CLUSTERGROUP_VERSION" --untar --untardir "$WORK" >/dev/null
    CHART="${WORK}/clustergroup"
fi

render_root() { # $1 = airgap|connected (baremetal chain)
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

render_group() { # $1 = cluster group; prints the connected-mode render
    # The same chains the patterns-operator resolves via sharedValueFiles
    # for each group (connected mode: global.airgap=false).
    local group="$1"
    local -a args=()
    case "$group" in
        baremetal|baremetal-hub|baremetal-spoke)
            args=(-f "${PATTERN_DIR}/overrides/values-None.yaml"
                  -f "${PATTERN_DIR}/overrides/values-storage-lvm.yaml"
                  -f "${PATTERN_DIR}/overrides/values-4.22.yaml"
                  -f "${PATTERN_DIR}/overrides/values-hw-intel-tdx.yaml"
                  -f "${PATTERN_DIR}/overrides/values-baremetal-connected.yaml") ;;
        azure|azure-spoke)
            args=(-f "${PATTERN_DIR}/overrides/values-Azure.yaml"
                  -f "${PATTERN_DIR}/overrides/values-4.22.yaml") ;;
        trusted-hub)
            args=(-f "${PATTERN_DIR}/overrides/values-None.yaml"
                  -f "${PATTERN_DIR}/overrides/values-4.22.yaml") ;;
        *)
            echo "render_group: unknown cluster group '$group'" >&2
            return 1 ;;
    esac
    helm template cg "${CHART}" \
        -f "${PATTERN_DIR}/values-global.yaml" \
        -f "${PATTERN_DIR}/values-${group}.yaml" \
        "${args[@]}" \
        --set global.repoURL=https://example.com/coco-pattern.git \
        --set global.targetRevision=render-gate \
        --set global.airgap=false \
        --set-string "global.mirrorRegistry=" \
        2>/dev/null
}

sub_source() { # $1 = rendered manifest, $2 = subscription name
    # Here-string: the early awk exit is safe with no upstream writer.
    awk -v wanted="$2" '
        /^  name: / { cur = $2 }
        /^  source: / { if (cur == wanted) { print $2; exit } }' <<< "$1"
}

acm_override() { # $1 = rendered manifest
    # sed -n '1p' instead of head -1: sed reads to EOF, head closes the pipe.
    grep -A1 'name: acm.mce_operator.source' <<< "$1" | grep 'value:' \
        | sed -n '1p' | sed "s/.*value: //; s/'//g; s/\"//g"
}

collateral_override() { # $1 = rendered manifest
    grep -A1 'name: kbs.tdx.collateralService' <<< "$1" | grep 'value:' \
        | sed -n '1p' | sed "s/.*value: //; s/'//g; s/\"//g"
}

obj_wave() { # $1 = rendered manifest, $2 = kind, $3 = metadata.name
    # prints the argocd.argoproj.io/sync-wave of the first matching object,
    # "-" when present without one, "ABSENT" when no such object.
    # The manifest travels on fd 3 so the heredoc below can carry the
    # program on stdin (python3 - reads its script from stdin).
    python3 - "$2" "$3" 3<<< "$1" <<'PYEOF'
import re, sys
kind, name = sys.argv[1], sys.argv[2]
for doc in open(3).read().split('\n---'):
    if not re.search(r'^kind: %s$' % kind, doc, re.M):
        continue
    if not re.search(r'^  name: %s$' % re.escape(name), doc, re.M):
        continue
    w = re.search(r'^\s+argocd\.argoproj\.io/sync-wave: "?\'?(-?[0-9]+)', doc, re.M)
    print(w.group(1) if w else '-')
    sys.exit(0)
print('ABSENT')
PYEOF
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
[[ "$val" == https://api.trustedservices.intel.com/sgx/certification/v4/ ]] \
    && pass "kbs.tdx.collateralService → Intel PCS" \
    || fail "kbs.tdx.collateralService → '${val}' (expected Intel PCS URL)"

# ── Sync-wave layout: every cluster group (connected mode) ───────────
echo "── sync-wave layout (all cluster groups, connected mode)"
declare -A RENDER=()
for group in baremetal baremetal-hub baremetal-spoke azure azure-spoke trusted-hub; do
    out="$(render_group "$group")" \
        && RENDER[$group]="$out" \
        || fail "$group connected render errored"
done

# Expected waves, one row per assertion: group|kind|metadata.name|wave.
# "-" = the object is present but carries no sync-wave annotation;
# "ABSENT" = the object must not render at all in that group.
while IFS='|' read -r group kind name wave; do
    if [[ -z "${group:-}" || "$group" == \#* ]]; then
        continue
    fi
    got="$(obj_wave "${RENDER[$group]:-}" "$kind" "$name")"
    if [[ "$got" == "$wave" ]]; then
        pass "$group: $kind/$name → $wave"
    else
        fail "$group: $kind/$name wave '${got}' (expected '${wave}')"
    fi
done <<'EOF'
# baremetal (single-cluster hub): full stack
# NOTE: the eso/lvms/cnv subscriptions render WITHOUT a sync-wave annotation
# ("-") — that is the current, live-validated state, pinned as-is.
baremetal|ClusterRoleBinding|coco-pattern-argocd-cluster-admin-bootstrap|-1
baremetal|Job|wait-for-vault-unsealed|5
baremetal|Application|acm|15
baremetal|Application|vault|0
baremetal|Application|openshift-external-secrets|0
baremetal|Application|kyverno|0
baremetal|Application|storage|0
baremetal|Subscription|advanced-cluster-management|10
baremetal|Subscription|openshift-external-secrets-operator|-
baremetal|Subscription|trustee-operator|10
baremetal|Subscription|sandboxed-containers-operator|10
baremetal|Subscription|openshift-cert-manager-operator|10
baremetal|Subscription|nfd|10
baremetal|Subscription|lvms-operator|-
baremetal|Subscription|kubevirt-hyperconverged|-
baremetal|Subscription|intel-device-plugins-operator|10
baremetal|Subscription|intel-tdx-dcap-operator|10
baremetal|Application|sandbox|10
baremetal|Application|baremetal|10
baremetal|Application|trustee|20
baremetal|Application|sandbox-policies|20
baremetal|Application|coco-kyverno-policies|20
baremetal|Application|intel-dcap|20
baremetal|Application|hello-openshift|30
baremetal|Application|kbs-access-curl|30
baremetal|Application|kbs-access-sealed|30
# baremetal-hub: same layout as baremetal (manages baremetal spokes)
baremetal-hub|ClusterRoleBinding|coco-pattern-argocd-cluster-admin-bootstrap|-1
baremetal-hub|Job|wait-for-vault-unsealed|5
baremetal-hub|Application|acm|15
baremetal-hub|Application|vault|0
baremetal-hub|Application|openshift-external-secrets|0
baremetal-hub|Application|kyverno|0
baremetal-hub|Application|storage|0
baremetal-hub|Subscription|advanced-cluster-management|10
baremetal-hub|Subscription|openshift-external-secrets-operator|-
baremetal-hub|Subscription|trustee-operator|10
baremetal-hub|Subscription|sandboxed-containers-operator|10
baremetal-hub|Subscription|openshift-cert-manager-operator|10
baremetal-hub|Subscription|nfd|10
baremetal-hub|Subscription|lvms-operator|-
baremetal-hub|Subscription|kubevirt-hyperconverged|-
baremetal-hub|Subscription|intel-device-plugins-operator|10
baremetal-hub|Subscription|intel-tdx-dcap-operator|10
baremetal-hub|Application|sandbox|10
baremetal-hub|Application|baremetal|10
baremetal-hub|Application|trustee|20
baremetal-hub|Application|sandbox-policies|20
baremetal-hub|Application|coco-kyverno-policies|20
baremetal-hub|Application|intel-dcap|20
baremetal-hub|Application|hello-openshift|30
baremetal-hub|Application|kbs-access-curl|30
baremetal-hub|Application|kbs-access-sealed|30
# baremetal-spoke: workloads only — no acm/vault/trustee stack, no wait Job
baremetal-spoke|ClusterRoleBinding|coco-pattern-argocd-cluster-admin-bootstrap|-1
baremetal-spoke|Job|wait-for-vault-unsealed|ABSENT
baremetal-spoke|Application|acm|ABSENT
baremetal-spoke|Application|vault|ABSENT
baremetal-spoke|Application|openshift-external-secrets|0
baremetal-spoke|Application|kyverno|0
baremetal-spoke|Subscription|advanced-cluster-management|ABSENT
baremetal-spoke|Subscription|openshift-external-secrets-operator|-
baremetal-spoke|Subscription|trustee-operator|ABSENT
baremetal-spoke|Subscription|sandboxed-containers-operator|10
baremetal-spoke|Subscription|openshift-cert-manager-operator|10
baremetal-spoke|Subscription|nfd|10
baremetal-spoke|Application|sandbox|10
baremetal-spoke|Application|baremetal|10
baremetal-spoke|Application|trustee|ABSENT
baremetal-spoke|Application|sandbox-policies|20
baremetal-spoke|Application|coco-kyverno-policies|20
baremetal-spoke|Application|hello-openshift|30
baremetal-spoke|Application|kbs-access-curl|30
baremetal-spoke|Application|kbs-access-sealed|30
# azure (single-cluster): full stack
azure|ClusterRoleBinding|coco-pattern-argocd-cluster-admin-bootstrap|-1
azure|Job|wait-for-vault-unsealed|5
azure|Application|acm|15
azure|Application|vault|0
azure|Application|openshift-external-secrets|0
azure|Application|kyverno|0
azure|Subscription|advanced-cluster-management|10
azure|Subscription|openshift-external-secrets-operator|-
azure|Subscription|trustee-operator|10
azure|Subscription|sandboxed-containers-operator|10
azure|Subscription|openshift-cert-manager-operator|10
azure|Application|sandbox|10
azure|Application|trustee|20
azure|Application|sandbox-policies|20
azure|Application|coco-kyverno-policies|20
azure|Application|hello-openshift|30
azure|Application|kbs-access-curl|30
azure|Application|kbs-access-sealed|30
# azure-spoke: workloads only — no acm/vault/trustee stack, no policies and
# no kyverno engine either (unlike baremetal-spoke, which carries kyverno)
azure-spoke|ClusterRoleBinding|coco-pattern-argocd-cluster-admin-bootstrap|-1
azure-spoke|Job|wait-for-vault-unsealed|ABSENT
azure-spoke|Application|acm|ABSENT
azure-spoke|Application|vault|ABSENT
azure-spoke|Application|openshift-external-secrets|0
azure-spoke|Application|kyverno|ABSENT
azure-spoke|Subscription|advanced-cluster-management|ABSENT
azure-spoke|Subscription|openshift-external-secrets-operator|-
azure-spoke|Subscription|trustee-operator|ABSENT
azure-spoke|Subscription|sandboxed-containers-operator|10
azure-spoke|Subscription|openshift-cert-manager-operator|10
azure-spoke|Application|sandbox|10
azure-spoke|Application|trustee|ABSENT
azure-spoke|Application|sandbox-policies|ABSENT
azure-spoke|Application|coco-kyverno-policies|ABSENT
azure-spoke|Application|hello-openshift|30
azure-spoke|Application|kbs-access-curl|30
azure-spoke|Application|kbs-access-sealed|30
# trusted-hub: hub stack (trustee/acm/vault/kyverno), no workloads, no sandbox sub
trusted-hub|ClusterRoleBinding|coco-pattern-argocd-cluster-admin-bootstrap|-1
trusted-hub|Job|wait-for-vault-unsealed|5
trusted-hub|Application|acm|15
trusted-hub|Application|vault|0
trusted-hub|Application|openshift-external-secrets|0
trusted-hub|Application|kyverno|0
trusted-hub|Subscription|advanced-cluster-management|10
trusted-hub|Subscription|openshift-external-secrets-operator|-
trusted-hub|Subscription|trustee-operator|10
trusted-hub|Subscription|sandboxed-containers-operator|ABSENT
trusted-hub|Subscription|openshift-cert-manager-operator|10
trusted-hub|Application|trustee|20
trusted-hub|Application|sandbox-policies|20
trusted-hub|Application|hello-openshift|ABSENT
trusted-hub|Application|kbs-access-curl|ABSENT
trusted-hub|Application|kbs-access-sealed|ABSENT
EOF

# ── RBAC bootstrap bridge (patterns-operator#887) ───────────────────
echo "── RBAC bridge"
for mode in airgap connected; do
    out="$(render_root "$mode")" || { fail "$mode root render errored"; continue; }
    # All documents mentioning the bridge name (the CRB itself, plus the
    # helm-values ConfigMap which embeds the values indented). The real CRB is
    # distinguished by an UNINDENTED "kind: ClusterRoleBinding" line.
    block="$(awk -v RS='---' '/coco-pattern-argocd-cluster-admin-bootstrap/' <<< "$out")"
    if [[ -z "$block" ]]; then
        fail "$mode: RBAC bridge CRB missing from root render"
        continue
    fi
    ok=1
    grep -q "^kind: ClusterRoleBinding" <<< "$block" || ok=0
    grep -q "cluster-admin$" <<< "$block" || ok=0
    grep -q "vp-gitops-argocd-application-controller" <<< "$block" || ok=0
    grep -q 'sync-wave: "-1"' <<< "$block" || ok=0
    if [[ $ok -eq 1 ]]; then
        pass "$mode: RBAC bridge CRB at wave -1 for the controller SA"
    else
        fail "$mode: RBAC bridge CRB malformed (kind/role/subject/wave)"
    fi
done

# ── Workload charts ──────────────────────────────────────────────────
echo "── workload charts"
for chart in hello-openshift kbs-access-curl kbs-access-sealed; do
    out="$(helm template wg "${PATTERN_DIR}/charts/coco-supported/${chart}" \
        --set global.coco.runtimeClassName=kata-cc 2>/dev/null)" \
        || { fail "$chart connected render errored"; continue; }
    if grep -q "registry.redhat.io/ubi9/httpd-24@sha256:68a91ff" <<< "$out"; then
        pass "$chart connected: upstream image unchanged"
    else
        fail "$chart connected: image not the upstream registry.redhat.io reference"
    fi

    out="$(helm template wg "${PATTERN_DIR}/charts/coco-supported/${chart}" \
        --set global.coco.runtimeClassName=kata-cc --set global.airgap=true \
        --set-string "global.mirrorRegistry=${MIRROR_ROOT}" 2>/dev/null)" \
        || { fail "$chart airgap render errored"; continue; }
    if grep -q "${MIRROR_ROOT}/ubi9/httpd-24@sha256:68a91ff" <<< "$out" \
        && ! grep -q "registry.redhat.io/ubi9" <<< "$out"; then
        pass "$chart airgap: image rewritten to ${MIRROR_ROOT}/ubi9/..."
    else
        fail "$chart airgap: image not rewritten to the mirror root"
    fi
done

# initImage (registry.access.redhat.com source path)
out="$(helm template x "${PATTERN_DIR}/charts/coco-supported/kbs-access-curl" \
    --set global.coco.runtimeClassName=kata-cc --set global.airgap=true \
    --set-string "global.mirrorRegistry=${MIRROR_ROOT}" 2>/dev/null)" \
    && grep -q "${MIRROR_ROOT}/ubi9/ubi:latest" <<< "$out" \
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

# ── Workload image-rewrite edge cases ────────────────────────────────
image_rewrite_case() { # $1 = chart, $2 = label, $3 = image in, $4 = expected
    local out
    out="$(helm template wg "${PATTERN_DIR}/charts/coco-supported/$1" \
        --set global.coco.runtimeClassName=kata-cc --set global.airgap=true \
        --set-string "global.mirrorRegistry=${MIRROR_ROOT}" \
        --set-string "image=$3" 2>/dev/null)" \
        || { fail "$1 airgap rewrite ($2): render errored"; return; }
    # The expected reference must appear as a complete image: value (anchored
    # at end of line), and no double mirror prefix anywhere in the render.
    if grep -q "image: $4\$" <<< "$out" \
        && ! grep -q "${MIRROR_ROOT}/${MIRROR_ROOT}" <<< "$out"; then
        pass "$1 airgap rewrite ($2): $3 → $4"
    else
        fail "$1 airgap rewrite ($2): '$3' did not render as '$4'"
    fi
}
for chart in hello-openshift kbs-access-curl kbs-access-sealed; do
    image_rewrite_case "$chart" "already-mirrored" \
        "${MIRROR_ROOT}/ubi9/httpd-24:pass" "${MIRROR_ROOT}/ubi9/httpd-24:pass"
    image_rewrite_case "$chart" "hostless" \
        "library/httpd:2.4" "${MIRROR_ROOT}/library/httpd:2.4"
    image_rewrite_case "$chart" "localhost" \
        "localhost:5000/foo:latest" "${MIRROR_ROOT}/foo:latest"
done

# ── Workload image helper sync ───────────────────────────────────────
# hello-openshift, kbs-access-curl and kbs-access-sealed each carry a copy
# of the <chart>.image helper (path-rendered charts cannot share a library
# template). Extract each copy (from the {{/* line preceding the "Render a
# workload container image" comment to end of file), normalise the define
# name, and require all three to be byte-identical.
image_helper_block() { # $1 = chart; prints the normalised helper block
    local f="${PATTERN_DIR}/charts/coco-supported/$1/templates/_helpers.tpl" start
    start="$(awk '/Render a workload container image/ {print NR - 1; exit}' "$f")"
    if [[ -z "$start" ]]; then
        return 1
    fi
    tail -n +"$start" "$f" | sed 's/^{{- define "[a-z-]*\.image" -}}$/{{- define "workload.image" -}}/'
}
echo "── workload image helper sync"
sync_ok=1
ref_sha=""
ref_chart=""
for chart in hello-openshift kbs-access-curl kbs-access-sealed; do
    if ! block="$(image_helper_block "$chart")"; then
        fail "$chart: image helper block not found in templates/_helpers.tpl"
        sync_ok=0
        continue
    fi
    sha="$(printf '%s' "$block" | sha256sum | cut -d' ' -f1)"
    if [[ -z "$ref_sha" ]]; then
        ref_sha="$sha"
        ref_chart="$chart"
    elif [[ "$sha" != "$ref_sha" ]]; then
        fail "$chart: image helper differs from $ref_chart (sha256 $sha vs $ref_sha)"
        sync_ok=0
    fi
done
if [[ $sync_ok -eq 1 ]]; then
    pass "image helper identical across the three workload charts (modulo define name)"
fi

# ── Verdict ──────────────────────────────────────────────────────────
echo ""
if [[ $FAILS -eq 0 ]]; then
    echo "RENDER GATE: PASS (0 failures)"
else
    echo "RENDER GATE: FAIL (${FAILS} failures)"
    exit 1
fi
