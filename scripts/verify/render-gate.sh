#!/usr/bin/env bash
# Render gate for the CoCo pattern values chain, both connectivity modes.
#
# SCOPE — only what the OCP 5.0 compatibility work can regress and no
# other repo tooling covers (`make validate-schema` checks each values
# file against the chart schema; `make show` renders for humans;
# `make argo-healthcheck` needs a live cluster):
#   - DCAP channel / OperatorGroup / imageset agreement (4.22 vs 5.0)
#   - version-overlay path resolution (the sharedValueFiles chains)
#   - catalog-source naming vs the version-pinned airgap overlays
#   - airgap/connected mode split (subscription sources, workload images)
#   - the 5.0 imagePullPolicy workaround (issue #176), NFD operand pin,
#     namespaces-as-maps key parity, the CRB sync-wave knob
# NOT here: a golden table of every sync-wave in every group, and
# per-chart copies of assertions licensed by the helper-sync check —
# the wave layout predates this branch and is pinned by the qualifying
# deploy records.
#
# Usage: render-gate.sh [mirror-root]; needs helm+python3; pulls the
# clustergroup chart unless CLUSTERGROUP_CHART is a local dir.
# CLUSTER_VERSION (default 4.22) selects the version overlay.
# Pipes: here-strings/fds — `echo|grep` SIGPIPEs (pipefail).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CLUSTERGROUP_VERSION="0.9.60"
GROUP="baremetal"
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

# Common helm args: repo coordinates and the version knob, shared by every
# render below.
common_args=(
    --set global.repoURL=https://example.com/coco-pattern.git
    --set global.targetRevision=render-gate
    --set global.vpArgoNamespace=vp-gitops
    --set-string "global.clusterVersion=${CLUSTER_VERSION}"
)

# helm template with stderr captured to a temp file and replayed only on
# failure: a broken chart must not surface as a bare "render errored".
# $1 = failure label, remaining args = helm args.
render() {
    local label="$1" errfile rc=0 out
    shift
    errfile="$(mktemp)"
    out=$(helm template cg "${CHART}" "$@" 2>"$errfile") || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "helm template failed (${label}):" >&2
        sed 's/^/    /' "$errfile" >&2 || true
        rm -f "$errfile"
        return $rc
    fi
    rm -f "$errfile"
    printf '%s\n' "$out"
}

render_root() { # $1 = airgap|connected (baremetal chain)
    local mode="$1" overlay
    if [[ "$mode" = airgap ]]; then
        overlay="$AIRGAP_OVERLAY"
    else
        overlay="values-baremetal-connected"
    fi
    render "${mode} root render" \
        -f "${PATTERN_DIR}/values-global.yaml" \
        -f "${PATTERN_DIR}/values-${GROUP}.yaml" \
        -f "${PATTERN_DIR}/overrides/values-storage-lvm.yaml" \
        -f "${PATTERN_DIR}/overrides/${VERSION_OVERLAY}.yaml" \
        -f "${PATTERN_DIR}/overrides/values-hw-intel-tdx.yaml" \
        -f "${PATTERN_DIR}/overrides/${overlay}.yaml" \
        "${common_args[@]}" \
        --set global.airgap="$([ "$mode" = airgap ] && echo true || echo false)" \
        --set-string "global.mirrorRegistry=$([ "$mode" = airgap ] && echo "$MIRROR_ROOT" || echo '')"
}

render_group() { # $1 = cluster group; prints the connected-mode render
    # The same chains the patterns-operator resolves via sharedValueFiles
    # for each group (connected mode: global.airgap=false).
    local group="$1"
    local -a args=()
    case "$group" in
        baremetal-hub)
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
        azure)
            args=(-f "${PATTERN_DIR}/overrides/values-Azure.yaml"
                  -f "${PATTERN_DIR}/overrides/values-${CLUSTER_VERSION}.yaml") ;;
        *)
            echo "render_group: unknown cluster group '$group'" >&2
            return 1 ;;
    esac
    render "${group} connected render" \
        -f "${PATTERN_DIR}/values-global.yaml" \
        -f "${PATTERN_DIR}/values-${group}.yaml" \
        "${args[@]}" \
        "${common_args[@]}" \
        --set global.airgap=false \
        --set-string "global.mirrorRegistry="
}

sub_source() { # $1 = rendered manifest, $2 = subscription name
    # Here-string: the early awk exit is safe with no upstream writer.
    awk -v wanted="$2" '
        /^  name: / { cur = $2 }
        /^  source: / { if (cur == wanted) { print $2; exit } }' <<< "$1"
}

sub_channel() { # $1 = rendered manifest, $2 = subscription name
    awk -v wanted="$2" '
        /^  name: / { cur = $2 }
        /^  channel: / { if (cur == wanted) { print $2; exit } }' <<< "$1"
}

value_override() { # $1 = rendered manifest, $2 = parameter name
    grep -A1 "name: $2" <<< "$1" | grep 'value:' \
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

# ── Renders ───────────────────────────────────────────────────────────
# Root renders are reused by every later section that needs them.
echo "── renders (version ${CLUSTER_VERSION}, mirror ${MIRROR_ROOT})"
AIRGAP="$(render_root airgap)" || fail "airgap root render errored"
CONNECTED="$(render_root connected)" || fail "connected root render errored"
HUB="$(render_group baremetal-hub)" || fail "baremetal-hub connected render errored"
SPOKE="$(render_group baremetal-spoke)" || fail "baremetal-spoke connected render errored"
AZURE="$(render_group azure)" || fail "azure connected render errored"

# ── Airgap mode: subscription sources + mode-dependent values ────────
echo "── airgap mode (global.airgap=true)"
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

val="$(value_override "$AIRGAP" acm.mce_operator.source)"
[[ "$val" == "$REDHAT_CS" ]] \
    && pass "acm.mce_operator.source → $val" \
    || fail "acm.mce_operator.source → '${val}' (expected ${REDHAT_CS})"

val="$(value_override "$AIRGAP" kbs.tdx.collateralService)"
[[ "$val" == file:///opt/confidential-containers/attestation-service/tdx/platform_collaterals.json ]] \
    && pass "kbs.tdx.collateralService → file:// backend" \
    || fail "kbs.tdx.collateralService → '${val}' (expected the file:// backend)"

# ── Connected mode: the same knobs flip back ──────────────────────────
echo "── connected mode (global.airgap=false)"
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

val="$(value_override "$CONNECTED" kbs.tdx.collateralService)"
[[ "$val" == https://api.trustedservices.intel.com/sgx/certification/v4/ ]] \
    && pass "kbs.tdx.collateralService → Intel PCS" \
    || fail "kbs.tdx.collateralService → '${val}' (expected Intel PCS URL)"

# ── DCAP: channel, OperatorGroup, imageset consistency ──────────────
# DCAP is version-divergent (4.22: alpha channel, AllNamespaces; 5.0:
# stable, OwnNamespace — see the PR description). Assert the render, the
# OperatorGroup and the imageset stay consistent.
echo "── Intel DCAP channel / OperatorGroup / imageset consistency (version ${CLUSTER_VERSION})"
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

# ── Resolved value-file chains ────────────────────────────────────────
# The sharedValueFiles tpl resolution is pinned end-to-end AND in order:
# a reordered, duplicated or renamed entry is as broken as a missing one.
# baremetal (root render, both modes) covers the 5.0 divert to
# values-5.0-baremetal.yaml; baremetal-hub proves the second copy of the
# tpl did not drift; azure covers the shared values-<ver>.yaml overlay
# path the non-baremetal groups take (values-5.0.yaml on 5.0).
echo "── resolved overlay chains, exact order (version ${CLUSTER_VERSION})"

# Ordered $patternref entries of the first valueFiles block in a render.
valuefiles_list() { # $1 = rendered manifest
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

# Expected chain for a group: chart-prefixed globals, then the
# sharedValueFiles chain (platform, storage, version, hw, mode).
expected_valuefiles() { # $1 = group, $2... = shared overlay file names
    local group="$1" overlay
    shift
    printf '$patternref/values-global.yaml\n'
    printf '$patternref/values-%s.yaml\n' "$group"
    printf '$patternref/values-%s-%s.yaml\n' "$CLUSTER_VERSION" "$group"
    for overlay in "$@"; do
        printf '$patternref/overrides/%s.yaml\n' "${overlay%.yaml}"
    done
}

check_chain() { # $1 = label, $2 = rendered manifest, $3 = expected chain
    local actual
    actual="$(valuefiles_list "$2")"
    if [[ "$actual" == "$3" ]]; then
        pass "$1: exact ordered valueFiles chain"
    else
        fail "$1: valueFiles chain mismatch"
        # `|| true`: diff exits 1 on mismatch — under set -e that would
        # abort the gate before the verdict line.
        diff <(printf '%s\n' "$3") <(printf '%s\n' "$actual") | sed 's/^/      /' || true
    fi
}

check_chain "baremetal airgap" "$AIRGAP" \
    "$(expected_valuefiles baremetal values- values-storage-lvm "${VERSION_OVERLAY}" values-hw-intel-tdx "${AIRGAP_OVERLAY}")"
check_chain "baremetal connected" "$CONNECTED" \
    "$(expected_valuefiles baremetal values- values-storage-lvm "${VERSION_OVERLAY}" values-hw-intel-tdx values-baremetal-connected)"
check_chain "baremetal-hub connected" "$HUB" \
    "$(expected_valuefiles baremetal-hub values- values-storage-lvm "${VERSION_OVERLAY}" values-hw-intel-tdx values-baremetal-connected)"
check_chain "azure connected" "$AZURE" \
    "$(expected_valuefiles azure values- "values-${CLUSTER_VERSION}")"

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
# fix); every other combination keeps the default. Each chart carries
# its own copy of the gate, so every chart is rendered.
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

# ── Sync-wave layout: high-signal rows only ───────────────────────────
# The full per-group golden table was retired (see the header): the wave
# layout predates this branch and is pinned by the qualifying deploy
# records. These rows guard the layout properties that are non-obvious
# and cheap to break while editing the group values files:
#   - tier ordering (job 5 → operators 10 → apps 20 → workloads 30)
#   - eso renders WITHOUT a wave (live-validated; do not "fix" it)
#   - the chart CRB: wave -1 on hubs, NO wave on spokes (ACM pre-creates)
#   - spokes render workloads only (trust stack ABSENT)
echo "── sync-wave layout (structural rows)"
declare -A RENDER=( [baremetal]="$CONNECTED" [baremetal-hub]="$HUB" [baremetal-spoke]="$SPOKE" )
# Rows: group|kind|metadata.name|wave. "-" = present without a wave;
# "ABSENT" = must not render at all in that group.
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
baremetal|ClusterRoleBinding|vp-gitops-cluster-admin-rolebinding|-1
baremetal|Job|wait-for-vault-unsealed|5
baremetal|Subscription|openshift-external-secrets-operator|-
baremetal|Subscription|trustee-operator|10
baremetal|Application|intel-dcap|20
baremetal|Application|hello-openshift|30
baremetal-hub|Subscription|intel-tdx-dcap-operator|10
baremetal-hub|Application|trustee|20
baremetal-spoke|ClusterRoleBinding|vp-gitops-cluster-admin-rolebinding|-
baremetal-spoke|Application|acm|ABSENT
baremetal-spoke|Application|trustee|ABSENT
baremetal-spoke|Application|hello-openshift|30
EOF

# ── Cluster-admin CRB (chart knob, patterns-operator#887) ────────────
echo "── cluster-admin CRB"
for mode in AIRGAP CONNECTED; do
    out="${!mode}"
    mode_label="${mode,,}"
    # All documents mentioning the CRB name (the CRB itself, plus the
    # helm-values ConfigMap which embeds the values indented). The real CRB is
    # distinguished by an UNINDENTED "kind: ClusterRoleBinding" line.
    block="$(awk -v RS='---' '/vp-gitops-cluster-admin-rolebinding/' <<< "$out")"
    if [[ -z "$block" ]]; then
        fail "$mode_label: chart cluster-admin CRB missing from root render"
        continue
    fi
    ok=1
    grep -q "^kind: ClusterRoleBinding" <<< "$block" || ok=0
    grep -q "cluster-admin$" <<< "$block" || ok=0
    grep -q "vp-gitops-argocd-application-controller" <<< "$block" || ok=0
    grep -q 'sync-wave: "-1"' <<< "$block" || ok=0
    if [[ $ok -eq 1 ]]; then
        pass "$mode_label: chart cluster-admin CRB at wave -1 for the controller SA"
    else
        fail "$mode_label: chart cluster-admin CRB malformed (kind/role/subject/wave)"
    fi
    # No duplicate: the pre-0.9.59 hand-rolled bridge must not render anywhere.
    dup="$(awk -v RS='---' '/coco-pattern-argocd-cluster-admin-bootstrap/' <<< "$out")"
    if [[ -n "$dup" ]]; then
        fail "$mode_label: hand-rolled bootstrap CRB still rendered (duplicate)"
    else
        pass "$mode_label: no hand-rolled bootstrap CRB duplicate"
    fi
done

# ── Workload image rewrite ────────────────────────────────────────────
# hello-openshift carries the rewrite assertions; the three charts' image
# helpers are asserted byte-identical below, so the other two inherit the
# coverage. kbs-access-curl adds the initImage path (a different source
# registry shape).
echo "── workload charts (image rewrite)"
out="$(helm template wg "${PATTERN_DIR}/charts/coco-supported/hello-openshift" \
    --set global.coco.runtimeClassName=kata-cc 2>/dev/null)" \
    || fail "hello-openshift connected render errored"
if grep -q "registry.redhat.io/ubi9/httpd-24@sha256:68a91ff" <<< "$out"; then
    pass "hello-openshift connected: upstream image unchanged"
else
    fail "hello-openshift connected: image not the upstream registry.redhat.io reference"
fi

out="$(helm template wg "${PATTERN_DIR}/charts/coco-supported/hello-openshift" \
    --set global.coco.runtimeClassName=kata-cc --set global.airgap=true \
    --set-string "global.mirrorRegistry=${MIRROR_ROOT}" 2>/dev/null)" \
    || fail "hello-openshift airgap render errored"
if grep -q "${MIRROR_ROOT}/ubi9/httpd-24@sha256:68a91ff" <<< "$out" \
    && ! grep -q "registry.redhat.io/ubi9" <<< "$out"; then
    pass "hello-openshift airgap: image rewritten to ${MIRROR_ROOT}/ubi9/..."
else
    fail "hello-openshift airgap: image not rewritten to the mirror root"
fi

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

# Rewrite edge cases (helper logic; one chart suffices — see helper sync):
# already-mirrored input must not double-prefix; hostless and localhost
# references are rebased under the mirror root.
image_rewrite_case() { # $1 = label, $2 = image in, $3 = expected
    local out
    out="$(helm template wg "${PATTERN_DIR}/charts/coco-supported/hello-openshift" \
        --set global.coco.runtimeClassName=kata-cc --set global.airgap=true \
        --set-string "global.mirrorRegistry=${MIRROR_ROOT}" \
        --set-string "image=$2" 2>/dev/null)" \
        || { fail "airgap rewrite ($1): render errored"; return; }
    # The expected reference must appear as a complete image: value (anchored
    # at end of line), and no double mirror prefix anywhere in the render.
    if grep -q "image: $3\$" <<< "$out" \
        && ! grep -q "${MIRROR_ROOT}/${MIRROR_ROOT}" <<< "$out"; then
        pass "airgap rewrite ($1): $2 → $3"
    else
        fail "airgap rewrite ($1): '$2' did not render as '$3'"
    fi
}
image_rewrite_case "already-mirrored" \
    "${MIRROR_ROOT}/ubi9/httpd-24:pass" "${MIRROR_ROOT}/ubi9/httpd-24:pass"
image_rewrite_case "hostless" \
    "library/httpd:2.4" "${MIRROR_ROOT}/library/httpd:2.4"
image_rewrite_case "localhost" \
    "localhost:5000/foo:latest" "${MIRROR_ROOT}/foo:latest"

# ── Workload image helper sync ────────────────────────────────────────
# The three path-rendered charts each carry a copy of the <chart>.image
# helper (no shared library templates); hash each copy (define name
# normalised) and require all three byte-identical. This is what
# licenses testing the image rewrite on one chart only.
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
for chart in hello-openshift kbs-access-curl kbs-access-sealed; do
    if ! block="$(image_helper_block "$chart")"; then
        fail "$chart: image helper block not found in templates/_helpers.tpl"
        sync_ok=0
        continue
    fi
    sha="$(printf '%s' "$block" | sha256sum | cut -d' ' -f1)"
    if [[ -z "$ref_sha" ]]; then
        ref_sha="$sha"
    elif [[ "$sha" != "$ref_sha" ]]; then
        fail "$chart: image helper differs from hello-openshift (sha256 $sha vs $ref_sha)"
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
