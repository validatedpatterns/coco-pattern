#!/usr/bin/env bash
# Render gate for the CoCo pattern values chain, both connectivity modes:
# catalog sources, sync-wave layout, chart CRB, workload image rewrite
# (see the section headers below). Usage: render-gate.sh [mirror-root];
# needs helm+python3; pulls the clustergroup chart unless CLUSTERGROUP_CHART
# is a local dir. CLUSTER_VERSION (default 4.22) selects the version
# overlay. Pipes: here-strings/fds — `echo|grep` SIGPIPEs (pipefail).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CLUSTERGROUP_VERSION="0.9.60"
GROUP="baremetal"
PLATFORM="None"                 # SNO: no values-<platform> file is present
CLUSTER_VERSION="${CLUSTER_VERSION:-4.22}"  # OCP minor: selects overrides/values-<ver>.yaml
MIRROR_ROOT="${1:-quay.example:443/mirror}"
FAILS=0

# Dashed minor (4.22 → 4-22) — the oc-mirror CatalogSource tag convention;
# derived, never hardcoded.
VER_DASHED="${CLUSTER_VERSION//./-}"
REDHAT_CS="cs-redhat-operator-index-v${VER_DASHED}"
CERTIFIED_CS="cs-certified-operator-index-v${VER_DASHED}"
# Airgap overlay: version-pinned (values-baremetal-airgap-<minor-dashed>.yaml
# for every minor), mirroring the sharedValueFiles tpl in values-baremetal.yaml.
AIRGAP_OVERLAY="values-baremetal-airgap-${VER_DASHED}"
# Version overlay for the baremetal chain: 5.0 diverts to
# values-5.0-baremetal.yaml (DCAP OperatorGroup — see that file).
VERSION_OVERLAY="values-${CLUSTER_VERSION}"
[[ "$CLUSTER_VERSION" == "5.0" ]] && VERSION_OVERLAY="values-5.0-baremetal"

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
    local mode="$1" overlay errfile rc=0 out
    if [[ "$mode" = airgap ]]; then
        overlay="$AIRGAP_OVERLAY"
    else
        overlay="values-baremetal-connected"
    fi
    # stderr goes to a temp file and is replayed only on failure: a broken
    # chart must not surface as a bare "root render errored".
    errfile="$(mktemp)"
    out=$(helm template cg "${CHART}" \
        -f "${PATTERN_DIR}/values-global.yaml" \
        -f "${PATTERN_DIR}/values-${GROUP}.yaml" \
        -f "${PATTERN_DIR}/overrides/values-storage-lvm.yaml" \
        -f "${PATTERN_DIR}/overrides/${VERSION_OVERLAY}.yaml" \
        -f "${PATTERN_DIR}/overrides/values-hw-intel-tdx.yaml" \
        -f "${PATTERN_DIR}/overrides/${overlay}.yaml" \
        --set global.repoURL=https://example.com/coco-pattern.git \
        --set global.targetRevision=render-gate \
        --set global.vpArgoNamespace=vp-gitops \
        --set-string "global.clusterVersion=${CLUSTER_VERSION}" \
        --set global.airgap="$([ "$mode" = airgap ] && echo true || echo false)" \
        --set-string "global.mirrorRegistry=$([ "$mode" = airgap ] && echo "$MIRROR_ROOT" || echo '')" \
        2>"$errfile") || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "helm template failed (${mode} root render):" >&2
        sed 's/^/    /' "$errfile" >&2 || true
        rm -f "$errfile"
        return $rc
    fi
    rm -f "$errfile"
    printf '%s\n' "$out"
}

render_group() { # $1 = cluster group; prints the connected-mode render
    # The same chains the patterns-operator resolves via sharedValueFiles
    # for each group (connected mode: global.airgap=false); the bare-metal
    # groups divert to the version-split overlay on 5.0.
    local group="$1" errfile rc=0 out
    local -a args=()
    case "$group" in
        baremetal|baremetal-hub)
            args=(-f "${PATTERN_DIR}/overrides/values-None.yaml"
                  -f "${PATTERN_DIR}/overrides/values-storage-lvm.yaml"
                  -f "${PATTERN_DIR}/overrides/${VERSION_OVERLAY}.yaml"
                  -f "${PATTERN_DIR}/overrides/values-hw-intel-tdx.yaml"
                  -f "${PATTERN_DIR}/overrides/values-baremetal-connected.yaml") ;;
        baremetal-spoke)
            args=(-f "${PATTERN_DIR}/overrides/values-None.yaml"
                  -f "${PATTERN_DIR}/overrides/values-storage-lvm.yaml"
                  -f "${PATTERN_DIR}/overrides/values-${CLUSTER_VERSION}.yaml"
                  -f "${PATTERN_DIR}/overrides/values-hw-intel-tdx.yaml"
                  -f "${PATTERN_DIR}/overrides/values-baremetal-connected.yaml") ;;
        azure|azure-spoke)
            args=(-f "${PATTERN_DIR}/overrides/values-Azure.yaml"
                  -f "${PATTERN_DIR}/overrides/values-${CLUSTER_VERSION}.yaml") ;;
        trusted-hub)
            args=(-f "${PATTERN_DIR}/overrides/values-None.yaml"
                  -f "${PATTERN_DIR}/overrides/values-${CLUSTER_VERSION}.yaml") ;;
        *)
            echo "render_group: unknown cluster group '$group'" >&2
            return 1 ;;
    esac
    # stderr to a temp file, replayed only on failure (an unknown flag or a
    # broken overlay must not surface as a bare "render errored").
    errfile="$(mktemp)"
    out=$(helm template cg "${CHART}" \
        -f "${PATTERN_DIR}/values-global.yaml" \
        -f "${PATTERN_DIR}/values-${group}.yaml" \
        "${args[@]}" \
        --set global.repoURL=https://example.com/coco-pattern.git \
        --set global.targetRevision=render-gate \
        --set global.vpArgoNamespace=vp-gitops \
        --set-string "global.clusterVersion=${CLUSTER_VERSION}" \
        --set global.airgap=false \
        --set-string "global.mirrorRegistry=" \
        2>"$errfile") || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "helm template failed (${group} connected render):" >&2
        sed 's/^/    /' "$errfile" >&2 || true
        rm -f "$errfile"
        return $rc
    fi
    rm -f "$errfile"
    printf '%s\n' "$out"
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
echo "── airgap mode (global.airgap=true, mirror=${MIRROR_ROOT}, version=${CLUSTER_VERSION})"
AIRGAP="$(render_root airgap)" || { fail "airgap root render errored"; }

for sub in intel-device-plugins-operator intel-tdx-dcap-operator; do
    src="$(sub_source "$AIRGAP" "$sub")"
    [[ "$src" == "$CERTIFIED_CS" ]] \
        && pass "subscription $sub → $src" \
        || fail "subscription $sub → '${src}' (expected ${CERTIFIED_CS})"
done

for sub in openshift-external-secrets-operator trustee-operator sandboxed-containers-operator; do
    src="$(sub_source "$AIRGAP" "$sub")"
    [[ "$src" == "$REDHAT_CS" ]] \
        && pass "subscription $sub → $src" \
        || fail "subscription $sub → '${src}' (expected ${REDHAT_CS})"
done

val="$(acm_override "$AIRGAP")"
[[ "$val" == "$REDHAT_CS" ]] \
    && pass "acm.mce_operator.source → $val" \
    || fail "acm.mce_operator.source → '${val}' (expected ${REDHAT_CS})"

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

# ── DCAP: channel, OperatorGroup, imageset consistency ──────────────
# DCAP is version-divergent (4.22: alpha channel, AllNamespaces; 5.0:
# stable, OwnNamespace — see the PR description). Assert the render, the
# OperatorGroup and the imageset stay consistent.
echo "── Intel DCAP channel / OperatorGroup / imageset consistency (version ${CLUSTER_VERSION})"
sub_channel() { # $1 = rendered manifest, $2 = subscription name
    awk -v wanted="$2" '
        /^  name: / { cur = $2 }
        /^  channel: / { if (cur == wanted) { print $2; exit } }' <<< "$1"
}

expected_channel="alpha"
expected_og="AllNamespaces"
[[ "$CLUSTER_VERSION" == "5.0" ]] && { expected_channel="stable"; expected_og="OwnNamespace"; }

for mode_label in AIRGAP CONNECTED; do
    chan="$(sub_channel "${!mode_label}" intel-tdx-dcap-operator)"
    [[ "$chan" == "$expected_channel" ]] \
        && pass "$mode_label: intel-tdx-dcap-operator channel → $chan" \
        || fail "$mode_label: intel-tdx-dcap-operator channel '${chan}' (expected ${expected_channel})"
done

og_block="$(awk -v RS='---' '/kind: OperatorGroup/ && /intel-dcap-operator-system-operator-group/' <<< "$CONNECTED")"
if [[ -z "$og_block" ]]; then
    fail "DCAP OperatorGroup missing from the render entirely (an absent OperatorGroup must not pass as AllNamespaces)"
elif [[ "$expected_og" == "OwnNamespace" ]]; then
    grep -q 'targetNamespaces:' <<< "$og_block" \
        && grep -q '  - intel-dcap-operator-system$' <<< "$og_block" \
        && pass "DCAP OperatorGroup → OwnNamespace (targetNamespaces pinned)" \
        || fail "DCAP OperatorGroup: expected OwnNamespace with targetNamespaces [intel-dcap-operator-system]"
else
    # AllNamespaces renders the OperatorGroup WITHOUT a spec at all
    grep -q '^spec:' <<< "$og_block" \
        && fail "DCAP OperatorGroup: expected AllNamespaces (no spec) on ${CLUSTER_VERSION}" \
        || pass "DCAP OperatorGroup → AllNamespaces (no spec)"
fi

imageset_channel="$(python3 - "${PATTERN_DIR}/airgap/imageset-config-${CLUSTER_VERSION}.yaml" <<'PYEOF'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
for catalog in cfg["mirror"]["operators"]:
    for pkg in catalog.get("packages", []):
        if pkg.get("name") == "intel-tdx-dcap-operator":
            print(pkg["channels"][0]["name"])
            sys.exit(0)
print("MISSING")
PYEOF
)"
[[ "$imageset_channel" == "$expected_channel" ]] \
    && pass "imageset-config-${CLUSTER_VERSION}.yaml mirrors DCAP channel '$imageset_channel' (matches the render)" \
    || fail "imageset-config-${CLUSTER_VERSION}.yaml DCAP channel '${imageset_channel}' != rendered '${expected_channel}' — a fresh disconnected install cannot resolve the subscription"

# ── Resolved value-file chain in the root render ─────────────────────
# The sharedValueFiles tpl resolution is pinned end-to-end AND in order:
# a reordered or duplicated valueFiles entry is as broken as a missing one.
echo "── resolved overlay chain, exact order (version ${CLUSTER_VERSION})"

# Ordered $patternref entries of the first valueFiles block in a render.
valuefiles_list() { # $1 = rendered root manifest
    awk '
        /valueFiles:/ { inblock = 1; next }
        inblock && /parameters:/ { exit }
        inblock && /- "\$patternref\// {
            line = $0
            sub(/^[[:space:]]*- "/, "", line)
            sub(/".*$/, "", line)
            print line
        }
    ' <<< "$1"
}

# Expected chain for a bare-metal group: chart-prefixed globals, then the
# sharedValueFiles chain (platform, storage, version, hw, mode).
expected_valuefiles() { # $1 = group, $2 = mode overlay file name
    printf '$patternref/values-global.yaml\n'
    printf '$patternref/values-%s.yaml\n' "$1"
    printf '$patternref/values-%s-%s.yaml\n' "$CLUSTER_VERSION" "$1"
    printf '$patternref/overrides/values-.yaml\n'
    printf '$patternref/overrides/values-storage-lvm.yaml\n'
    printf '$patternref/overrides/%s.yaml\n' "${VERSION_OVERLAY}"
    printf '$patternref/overrides/values-hw-intel-tdx.yaml\n'
    printf '$patternref/overrides/%s.yaml\n' "$2"
}

for mode in airgap connected; do
    render_var="AIRGAP"
    [[ "$mode" == "connected" ]] && render_var="CONNECTED"
    actual="$(valuefiles_list "${!render_var}")"
    expected="$(expected_valuefiles baremetal "${AIRGAP_OVERLAY}")"
    [[ "$mode" == "connected" ]] && expected="$(expected_valuefiles baremetal values-baremetal-connected)"
    if [[ "$actual" == "$expected" ]]; then
        pass "baremetal ${mode}: exact ordered valueFiles chain (${VERSION_OVERLAY} + ${mode} overlay)"
    else
        fail "baremetal ${mode}: valueFiles chain mismatch"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/      /'
    fi
done
# The hub group rides the same shared chain (connected mode, render_group)
hub_connected="$(render_group baremetal-hub)" || fail "baremetal-hub connected render errored"
actual="$(valuefiles_list "$hub_connected")"
expected="$(expected_valuefiles baremetal-hub values-baremetal-connected)"
if [[ "$actual" == "$expected" ]]; then
    pass "baremetal-hub connected: exact ordered valueFiles chain"
else
    fail "baremetal-hub connected: valueFiles chain mismatch"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/      /'
fi

# ── Namespace-map overlay guard (5.0 overlay vs base) ────────────────
# namespaces are a map now, so values-5.0-baremetal.yaml pins only the
# DCAP entry (Helm deep-merges maps). Assert every overlay key exists in
# the base map — a typo'd key would silently create a new namespace.
echo "── namespaces-map keys: values-5.0-baremetal.yaml vs values-baremetal{,-hub}.yaml"
namespace_parity() { # $1 = base values file; prints OK or the divergence
    python3 - "$1" "${PATTERN_DIR}" <<'PYEOF'
import sys, yaml
base = yaml.safe_load(open(sys.argv[1]))["clusterGroup"]["namespaces"]
ovr = yaml.safe_load(open(f"{sys.argv[2]}/overrides/values-5.0-baremetal.yaml"))["clusterGroup"]["namespaces"]
if not isinstance(base, dict) or not isinstance(ovr, dict):
    print("FORM base=%s overlay=%s (both must be maps)" % (type(base).__name__, type(ovr).__name__))
    sys.exit(0)
for key, value in ovr.items():
    if key not in base:
        print(f"UNKNOWN KEY {key}: not in the base namespaces map (would create a new namespace)")
        sys.exit(0)
    if key != "intel-dcap-operator-system" and value != base[key]:
        print(f"ENTRY {key}: base={base[key]!r} overlay={value!r}")
        sys.exit(0)
print("OK")
PYEOF
}
for base_file in values-baremetal.yaml values-baremetal-hub.yaml; do
    parity="$(namespace_parity "${PATTERN_DIR}/${base_file}")"
    [[ "$parity" == "OK" ]] \
        && pass "overlay namespaces keys all resolve against ${base_file} (DCAP entry only)" \
        || fail "namespaces drift between ${base_file} and values-5.0-baremetal.yaml: $parity"
done

# ── Version-specific workload behaviour ──────────────────────────────
# 5.0 + kata-cc only: the CRI-O guest-pull defect forces imagePullPolicy:
# Always on digest-pinned kata-cc containers (issue #176 tracks the real
# fix); every other combination keeps the default.
echo "── workload imagePullPolicy (version ${CLUSTER_VERSION})"
declare -A EXPECT_ALWAYS=( [hello-openshift]=2 [kbs-access-curl]=1 [kbs-access-sealed]=1 )
for chart in hello-openshift kbs-access-curl kbs-access-sealed; do
    for rc in kata-cc kata-remote kata-cc-nvidia-gpu; do
        out="$(helm template wg "${PATTERN_DIR}/charts/coco-supported/${chart}" \
            --set global.coco.runtimeClassName=${rc} \
            --set-string "global.clusterVersion=${CLUSTER_VERSION}" 2>/dev/null)" \
            || { fail "$chart ${CLUSTER_VERSION}/${rc} render errored"; continue; }
        n="$(grep -c 'imagePullPolicy: Always' <<< "$out" || true)"
        if [[ "$CLUSTER_VERSION" == "5.0" && "$rc" == kata-cc* ]]; then
            [[ "$n" -eq "${EXPECT_ALWAYS[$chart]}" ]] \
                && pass "$chart: ${n}× imagePullPolicy Always on ${CLUSTER_VERSION}/${rc}" \
                || fail "$chart: ${n}× imagePullPolicy Always on ${CLUSTER_VERSION}/${rc} (expected ${EXPECT_ALWAYS[$chart]})"
        else
            [[ "$n" -eq 0 ]] \
                && pass "$chart: default pull policy on ${CLUSTER_VERSION}/${rc}" \
                || fail "$chart: imagePullPolicy Always must not render on ${CLUSTER_VERSION}/${rc}"
        fi
    done
done

# 5.0 only: NFD operand image is CSV-provided (openshift5 org, digest) —
# the 4.x tag pin must NOT render; 4.22 keeps the pinned tag.
nfd_img="$(helm template nfd "${PATTERN_DIR}/charts/all/baremetal" \
    -f "${PATTERN_DIR}/values-global.yaml" \
    --set-string "global.clusterVersion=${CLUSTER_VERSION}" 2>/dev/null \
    | grep 'image: registry.redhat.io/openshift4/ose-node-feature-discovery' || true)"
if [[ "$CLUSTER_VERSION" == "5.0" ]]; then
    [[ -z "$nfd_img" ]] \
        && pass "NFD operand unpinned on 5.0 (CSV digest from the openshift5 org)" \
        || fail "NFD operand still tag-pinned on 5.0: $nfd_img"
else
    [[ "$nfd_img" == *"ose-node-feature-discovery-rhel9:v${CLUSTER_VERSION}"* ]] \
        && pass "NFD operand tag-pinned on ${CLUSTER_VERSION}" \
        || fail "NFD operand pin wrong on ${CLUSTER_VERSION}: $nfd_img"
fi

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
# NOTE: the eso/lvms/cnv subscriptions render WITHOUT a sync-wave ("-"):
# live-validated state, pinned as-is. The cluster-admin CRB is the chart's
# vp-gitops-cluster-admin-rolebinding: -1 on non-spokes, none on spokes
# (ACM pre-creates it there; upstream reverted -1 for spokes, 61a99b4).
baremetal|ClusterRoleBinding|vp-gitops-cluster-admin-rolebinding|-1
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
baremetal-hub|ClusterRoleBinding|vp-gitops-cluster-admin-rolebinding|-1
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
# baremetal-spoke: workloads only — no acm/vault/trustee stack, no wait Job;
# the chart CRB renders WITHOUT a wave (ACM pre-creates it on managed spokes)
baremetal-spoke|ClusterRoleBinding|vp-gitops-cluster-admin-rolebinding|-
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
azure|ClusterRoleBinding|vp-gitops-cluster-admin-rolebinding|-1
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
# no kyverno engine either (unlike baremetal-spoke, which carries kyverno);
# the chart CRB renders WITHOUT a wave (ACM pre-creates it on managed spokes)
azure-spoke|ClusterRoleBinding|vp-gitops-cluster-admin-rolebinding|-
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
trusted-hub|ClusterRoleBinding|vp-gitops-cluster-admin-rolebinding|-1
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

# ── Cluster-admin CRB (chart knob, patterns-operator#887) ────────────
echo "── cluster-admin CRB"
for mode in airgap connected; do
    out="$(render_root "$mode")" || { fail "$mode root render errored"; continue; }
    # All documents mentioning the CRB name (the CRB itself, plus the
    # helm-values ConfigMap which embeds the values indented). The real CRB is
    # distinguished by an UNINDENTED "kind: ClusterRoleBinding" line.
    block="$(awk -v RS='---' '/vp-gitops-cluster-admin-rolebinding/' <<< "$out")"
    if [[ -z "$block" ]]; then
        fail "$mode: chart cluster-admin CRB missing from root render"
        continue
    fi
    ok=1
    grep -q "^kind: ClusterRoleBinding" <<< "$block" || ok=0
    grep -q "cluster-admin$" <<< "$block" || ok=0
    grep -q "vp-gitops-argocd-application-controller" <<< "$block" || ok=0
    grep -q 'sync-wave: "-1"' <<< "$block" || ok=0
    if [[ $ok -eq 1 ]]; then
        pass "$mode: chart cluster-admin CRB at wave -1 for the controller SA"
    else
        fail "$mode: chart cluster-admin CRB malformed (kind/role/subject/wave)"
    fi
    # No duplicate: the pre-0.9.59 hand-rolled bridge must not render anywhere.
    dup="$(awk -v RS='---' '/coco-pattern-argocd-cluster-admin-bootstrap/' <<< "$out")"
    if [[ -n "$dup" ]]; then
        fail "$mode: hand-rolled bootstrap CRB still rendered (duplicate)"
    else
        pass "$mode: no hand-rolled bootstrap CRB duplicate"
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
# The three path-rendered charts each carry a copy of the <chart>.image
# helper (they cannot share a library template). Hash the define body of
# each copy (define name normalised) and require all three byte-identical;
# comments are excluded so prose may drift between the copies.
image_helper_block() { # $1 = chart; prints the normalised helper block
    local f="${PATTERN_DIR}/charts/coco-supported/$1/templates/_helpers.tpl" start
    start="$(awk '/^{{- define "[a-z-]*\.image" -}}$/ {print NR; exit}' "$f")"
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
