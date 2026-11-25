#!/usr/bin/env bash
# Post-install bootstrap for disconnected CoCo pattern deployment.
# Run after oc-mirror completes and before deploying the pattern.
#
# Idempotent — safe to re-run. Each step checks current state before acting.

# Required env:
#   KUBECONFIG      — path to cluster kubeconfig

#   MIRROR_REGISTRY — mirror root INCLUDING the org path for Quay targets
#                     (e.g. quay.example:443/mirror). Direct references
#                     (workload image rewrites, ITMS mirrors, chart pulls)
#                     all carry the org path; a bare host:port gets 401/404
#                     on Quay.

# Optional env:
#   GIT_HTTP_PORT           — port for smart HTTP git server (default: 8080)
#   GIT_REPO_ROOT           — path to bare git repos (default: ~/public_html/git)
#   GIT_REPOS               — space-separated list of working copy dirs to serve
#   ENABLE_ROUTINGVIAHOST   — set to "true" to enable OVN routingViaHost (test-lab only)

# Modes (default: no args — run all steps):
#   --sync-repos-only     — only sync working copies to bare HTTP repos
#   --deploy-pattern      — deploy the Pattern CR directly (skip pattern.sh)
#   --fix-manifest-lists  — fix oc-mirror manifest list failures with skopeo
#   --repoint-subs        — re-run only the step 3d subscription repoint

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GIT_REPO_ROOT="${GIT_REPO_ROOT:-${HOME}/public_html/git}"
GIT_HTTP_PORT="${GIT_HTTP_PORT:-8080}"
MIRROR_REGISTRY="${MIRROR_REGISTRY:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${GREEN}===${NC} Step $1: $2 ${GREEN}===${NC}"; }

# Read a dotted key path from values-global.yaml with a default.
# Single implementation for every values read in this script: consistent
# missing-key and parse-failure handling (both return the default).
read_global_key() { # $1 = dotted key (e.g. global.clusterVersion), $2 = default
    local key="${1:?read_global_key: key required}" default="${2:-}"
    local val
    val=$(python3 -c "
import sys, yaml
try:
    d = yaml.safe_load(open('${PATTERN_DIR}/values-global.yaml')) or {}
except Exception:
    print('${default}'); sys.exit(0)
for part in '${key}'.split('.'):
    if not isinstance(d, dict) or part not in d:
        print('${default}'); sys.exit(0)
    d = d[part]
print('' if d is None else d)
" 2>/dev/null) || val="$default"
    echo "$val"
}

# Resolve the version-pinned airgap overlay path from global.clusterVersion,
# mirroring the sharedValueFiles tpl in values-baremetal.yaml: 4.22 keeps
# the historical unsuffixed name (byte-identical render with the qualified
# 4.22 deploy); other minors append the dashed version (5.0 → -5-0).
airgap_overlay_path() {
    local cluster_version suffix
    cluster_version=$(read_global_key global.clusterVersion '')
    if [[ -z "$cluster_version" ]]; then
        echo "${PATTERN_DIR}/overrides/values-baremetal-airgap.yaml"
        return
    fi
    if [[ "$cluster_version" == "4.22" ]]; then
        echo "${PATTERN_DIR}/overrides/values-baremetal-airgap.yaml"
    else
        suffix="${cluster_version//./-}"
        echo "${PATTERN_DIR}/overrides/values-baremetal-airgap-${suffix}.yaml"
    fi
}

# ─── Mode dispatch ───────────────────────────────────────────────
MODE="full"
case "${1:-}" in
    --sync-repos-only)    MODE="sync"; shift ;;
    --deploy-pattern)     MODE="deploy"; shift ;;
    --fix-manifest-lists) MODE="fix-manifests"; shift ;;
    --repoint-subs)       MODE="repoint"; shift ;;
esac

# ─── Step 1: Validate prerequisites ─────────────────────────────
validate_prereqs() {
    step 1 "Validate prerequisites"

    local missing=()
    for cmd in oc git python3; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required commands: ${missing[*]}"
        exit 1
    fi

    if [[ -z "${KUBECONFIG:-}" ]]; then
        error "KUBECONFIG is not set"
        exit 1
    fi
    if [[ ! -f "$KUBECONFIG" ]]; then
        error "KUBECONFIG file not found: $KUBECONFIG"
        exit 1
    fi

    if [[ -z "$MIRROR_REGISTRY" ]]; then
        error "MIRROR_REGISTRY is not set (mirror root INCLUDING the org path,"
        error "e.g. quay.example:443/mirror — a bare host:port gets 401/404 on Quay)"
        exit 1
    fi

    if ! oc whoami >/dev/null 2>&1; then
        error "Cannot connect to cluster. Check KUBECONFIG."
        exit 1
    fi
    info "Cluster: $(oc whoami --show-server 2>/dev/null)"
    info "Mirror:  $MIRROR_REGISTRY"
}

# ─── Step 2: Disable default CatalogSources ─────────────────────
disable_default_catalogs() {
    step 2 "Disable default CatalogSources"

    local current
    current=$(oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}' 2>/dev/null || echo "")
    if [[ "$current" == "true" ]]; then
        info "Already disabled — skipping"
    else
        oc patch OperatorHub cluster --type json \
            -p '[{"op":"add","path":"/spec/disableAllDefaultSources","value":true}]'
        info "Default CatalogSources disabled"
    fi

    info "Active catalogs:"
    oc get catalogsource -n openshift-marketplace --no-headers 2>/dev/null || true
}

# ─── Step 3: Apply CatalogSources from oc-mirror cluster-resources ──
# oc-mirror v2 generates cs-*.yaml with correct registry path and tag.
# Applying from oc-mirror output avoids hardcoding version numbers here.
# Stale CatalogSources (e.g. from prior OCP version) are deleted to prevent
# OLM ResolutionFailed from ImagePullBackOff on outdated catalog pods.
create_catalog_sources() {
    step 3 "Apply CatalogSources from oc-mirror cluster-resources"

    local workspace="${OC_MIRROR_WORKSPACE:-${HOME}/oc-mirror-workspace}"
    local cs_dir="${workspace}/working-dir/cluster-resources"

    if [[ ! -d "$cs_dir" ]]; then
        warn "oc-mirror cluster-resources not found at $cs_dir — skipping CatalogSource creation"
        return
    fi

    local applied=0
    for cs_file in "$cs_dir"/cs-*.yaml; do
        [[ -f "$cs_file" ]] || continue
        info "  Applying $(basename "$cs_file")"
        oc apply -f "$cs_file"
        applied=$(( applied + 1 ))   # avoid (( applied++ )) which exits when applied=0 under set -e
    done
    [[ $applied -eq 0 ]] && warn "No cs-*.yaml files found in $cs_dir"

    # Delete CatalogSources not present in current oc-mirror output
    local current_names
    current_names=$(ls "$cs_dir"/cs-*.yaml 2>/dev/null | xargs -I{} basename {} .yaml | paste -sd '|')
    if [[ -n "$current_names" ]]; then
        while IFS= read -r stale_ref; do
            [[ -z "$stale_ref" ]] && continue
            warn "  Deleting stale: $stale_ref"
            oc delete "$stale_ref" -n openshift-marketplace 2>/dev/null || true
        done < <(oc get catalogsource -n openshift-marketplace --no-headers -o name 2>/dev/null |                  grep -vE "$current_names" | grep -v 'marketplace-operator')
    fi

    info "CatalogSources applied: $applied"
    oc get catalogsource -n openshift-marketplace --no-headers 2>/dev/null || true
}

# ─── Step 3b: Apply ALL oc-mirror cluster-resources ─────────────
# oc-mirror generates: IDMS, ITMS, CatalogSource, ClusterCatalog (OLM v1),
# signature ConfigMap, and UpdateService (if applicable).
# All must be applied per post-mirror procedure.
apply_ocmirror_resources() {
    step "3b" "Apply all oc-mirror cluster-resources (IDMS, ITMS, CatalogSource, signatures)"

    local workspace="${HOME}/oc-mirror-workspace"
    local resources="${workspace}/working-dir/cluster-resources"

    if [[ ! -d "$resources" ]]; then
        warn "No oc-mirror cluster-resources at $resources — skipping"
        return
    fi

    # Apply IDMS (ImageDigestMirrorSet) — digest-based pull redirects.
    # Patch mirrorSourcePolicy: NeverContactSource on each entry so the cluster
    # never falls back to internet registries if a mirror pull fails.
    # Without this, a 404 from mirror-registry causes a fallback to quay.io
    # which hangs on the fake-gateway TCP timeout in airgap environments.
    for f in "$resources"/idms-*.yaml; do
        [[ -f "$f" ]] || continue
        info "  Applying $(basename "$f") with NeverContactSource policy"
        python3 -c "
import sys, yaml
docs = list(yaml.safe_load_all(open('$f')))
for doc in docs:
    if doc and doc.get('kind') == 'ImageDigestMirrorSet':
        for entry in doc.get('spec', {}).get('imageDigestMirrors', []):
            entry['mirrorSourcePolicy'] = 'NeverContactSource'
print(yaml.dump_all(docs, default_flow_style=False))
" | oc apply -f - || warn "  Failed to apply $(basename "$f")"
    done

    # Apply ITMS (ImageTagMirrorSet) — tag-based pull redirects.
    # Patch mirrorSourcePolicy: NeverContactSource to match IDMS policy.
    # Without this, MCO rejects re-renders when the same source appears in both
    # an IDMS (NeverContactSource) and an ITMS ((none)), blocking ALL registry
    # config updates until the conflict is resolved.
    for f in "$resources"/itms-*.yaml; do
        [[ -f "$f" ]] || continue
        info "  Applying $(basename "$f") with NeverContactSource policy"
        python3 -c "
import sys, yaml
docs = list(yaml.safe_load_all(open('$f')))
for doc in docs:
    if doc and doc.get('kind') == 'ImageTagMirrorSet':
        for entry in doc.get('spec', {}).get('imageTagMirrors', []):
            entry['mirrorSourcePolicy'] = 'NeverContactSource'
print(yaml.dump_all(docs, default_flow_style=False))
" | oc apply -f - || warn "  Failed to apply $(basename "$f")"
    done

    # Apply manually maintained ITMS (community-operator-pipeline-prod, intel, hashicorp)
    # __MIRROR_REGISTRY__ placeholders are substituted from $MIRROR_REGISTRY at apply
    # time (FR-017: canonical identity is the DNS name, so the mirrors follow the env).
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local manual_itms="${script_dir}/../airgap/itms-manual-mirrors.yaml"
    if [[ -f "$manual_itms" ]]; then
        info "  Applying manual ITMS: $(basename "$manual_itms") with NeverContactSource policy"
        MIRROR_REGISTRY="${MIRROR_REGISTRY}" python3 -c "
import sys, os, yaml
raw = open('$manual_itms').read()
mirror = os.environ.get('MIRROR_REGISTRY', '')
if mirror and '__MIRROR_REGISTRY__' in raw and mirror != '__MIRROR_REGISTRY__':
    raw = raw.replace('__MIRROR_REGISTRY__', mirror)
docs = list(yaml.safe_load_all(raw))
for doc in docs:
    if doc and doc.get('kind') == 'ImageTagMirrorSet':
        for entry in doc.get('spec', {}).get('imageTagMirrors', []):
            entry['mirrorSourcePolicy'] = 'NeverContactSource'
print(yaml.dump_all(docs, default_flow_style=False))
" | oc apply -f - || warn "  Failed to apply manual ITMS"
    fi

    # Apply signature ConfigMap — required for image signature verification
    for f in "$resources"/signature-configmap.yaml "$resources"/signature-configmap.json; do
        [[ -f "$f" ]] || continue
        info "  Applying $(basename "$f")"
        oc apply -f "$f" || warn "  Failed to apply $(basename "$f")"
    done

    # Apply ClusterCatalog (cc-*.yaml) — OLM v1 catalog API (OCP 4.22+)
    for f in "$resources"/cc-*.yaml; do
        [[ -f "$f" ]] || continue
        info "  Applying $(basename "$f")"
        oc apply -f "$f" || warn "  Failed to apply $(basename "$f")"
    done

    # Apply UpdateService if generated (for OCP update graph in disconnected environments)
    for f in "$resources"/updateservice-*.yaml; do
        [[ -f "$f" ]] || continue
        info "  Applying $(basename "$f")"
        oc apply -f "$f" || warn "  Failed to apply $(basename "$f")"
    done

    info "oc-mirror cluster-resources applied"
}

# ─── Step 3c: Normalise mirrorSourcePolicy on ALL cluster IDMS/ITMS ─
# The cluster bootstrap IDMS (named "image-digest-mirror") is embedded in the
# agent-config ignition by labctl at install time and applied before this script
# runs. It has no mirrorSourcePolicy. When any source appears in both that IDMS
# and a newer IDMS/ITMS with NeverContactSource, MCO reports a conflict and stops
# re-rendering registries.conf — silently blocking all future mirror rule updates.
# This step patches every IDMS and ITMS on the cluster, regardless of origin, so
# all entries are consistent. Idempotent — re-running is safe.
normalise_mirror_source_policy() {
    step "3c" "Normalise mirrorSourcePolicy on all cluster IDMS/ITMS objects"

    local changed=0 conflicts=0

    # Scratch file for the python MODIFIED/NOOP verdicts — mktemp, not a
    # fixed /tmp path: concurrent runs (or a stale file from a previous
    # run) would otherwise read each other's status.
    local status_file
    status_file="$(mktemp)"
    trap 'rm -f "$status_file"' RETURN

    # Patch all ImageDigestMirrorSet objects
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local patched
        patched=$(oc get imagedigestmirrorset "$name" -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
modified = False
for m in d.get('spec', {}).get('imageDigestMirrors', []):
    if m.get('mirrorSourcePolicy') != 'NeverContactSource':
        m['mirrorSourcePolicy'] = 'NeverContactSource'
        modified = True
for k in ['managedFields', 'resourceVersion', 'uid', 'generation', 'creationTimestamp']:
    d.get('metadata', {}).pop(k, None)
d.pop('status', None)
print(json.dumps(d))
print('MODIFIED' if modified else 'NOOP', file=sys.stderr)
" 2>"$status_file")
        local status; status=$(<"$status_file")
        if [[ "$status" == "MODIFIED" ]]; then
            echo "$patched" | oc apply -f - 2>/dev/null && \
                info "  Patched IDMS: $name" && changed=$(( changed + 1 ))
        else
            info "  IDMS already consistent: $name"
        fi
    done < <(oc get imagedigestmirrorset -o name 2>/dev/null | sed 's|.*/||')

    # Patch all ImageTagMirrorSet objects
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local patched
        patched=$(oc get imagetagmirrorset "$name" -o json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
modified = False
for m in d.get('spec', {}).get('imageTagMirrors', []):
    if m.get('mirrorSourcePolicy') != 'NeverContactSource':
        m['mirrorSourcePolicy'] = 'NeverContactSource'
        modified = True
for k in ['managedFields', 'resourceVersion', 'uid', 'generation', 'creationTimestamp']:
    d.get('metadata', {}).pop(k, None)
d.pop('status', None)
print(json.dumps(d))
print('MODIFIED' if modified else 'NOOP', file=sys.stderr)
" 2>"$status_file")
        local status; status=$(<"$status_file")
        if [[ "$status" == "MODIFIED" ]]; then
            echo "$patched" | oc apply -f - 2>/dev/null && \
                info "  Patched ITMS: $name" && changed=$(( changed + 1 ))
        else
            info "  ITMS already consistent: $name"
        fi
    done < <(oc get imagetagmirrorset -o name 2>/dev/null | sed 's|.*/||')

    # Verify no conflicts remain
    conflicts=$(python3 - <<'PYEOF'
import subprocess, json
from collections import defaultdict
def get_items(kind):
    r = subprocess.run(['oc','get',kind,'-o','json'], capture_output=True, text=True)
    return json.loads(r.stdout).get('items', []) if r.returncode == 0 else []
source_policies = defaultdict(set)
for item in get_items('imagedigestmirrorset'):
    for m in item.get('spec', {}).get('imageDigestMirrors', []):
        source_policies[m.get('source','')].add(m.get('mirrorSourcePolicy','(none)'))
for item in get_items('imagetagmirrorset'):
    for m in item.get('spec', {}).get('imageTagMirrors', []):
        source_policies[m.get('source','')].add(m.get('mirrorSourcePolicy','(none)'))
conflicts = [s for s, p in source_policies.items() if len(p) > 1]
print(len(conflicts))
for s in conflicts:
    print(f"  CONFLICT: {s} -> {source_policies[s]}", file=__import__('sys').stderr)
PYEOF
)
    if [[ "$conflicts" -gt 0 ]]; then
        warn "  $conflicts mirrorSourcePolicy conflicts remain — MCO may still be blocked"
    else
        info "  PASS: No mirrorSourcePolicy conflicts"
    fi

    if [[ "$changed" -gt 0 ]]; then
        warn "  $changed objects patched — MCO will re-render registries.conf"
        warn "  On SNO this triggers a node reboot. Wait for 'oc get nodes' to show Ready"
        warn "  before proceeding with D-2."
    fi
}

# Step 4 removed — ITMS is now applied from oc-mirror cluster-resources
# in Step 3b (itms-*.yaml) and from airgap/itms-manual-mirrors.yaml.
# The old inline ITMS used registry_base with /mirror/ prefix which was
# incorrect for single-registry (mirror-registry) architecture.

# ─── Step 3d: Repoint default-catalog subscriptions to the mirror catalog ─
# Safety net for runtime-created subscriptions (e.g. MCH's multicluster-engine)
# referencing the disabled default catalogs. ArgoCD-owned subscriptions are
# skipped (self-heal would revert an out-of-band patch; they are declarative
# via the airgap overlay / values-baremetal.yaml). Idempotent: make airgap-repoint-subs
repoint_default_catalog_subscriptions() {
    step "3d" "Repoint default-catalog subscriptions to mirrored catalogs"

    # Derive the oc-mirror catalog suffix from global.clusterVersion
    # (4.22 → v4-22), matching the operator index tags in the imageset.
    local cluster_version catalog_suffix
    cluster_version=$(read_global_key global.clusterVersion '')
    if [[ -n "${cluster_version}" ]]; then
        catalog_suffix="v${cluster_version//./-}"
        info "Catalog suffix -${catalog_suffix} (from global.clusterVersion ${cluster_version})"
    else
        # Fallback: derive from the CatalogSources oc-mirror actually created.
        catalog_suffix=$(oc get catalogsources -n openshift-marketplace \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
            | grep -oE 'index-v[0-9]+-[0-9]+' | head -1 | sed 's/.*index-//' || true)
        if [[ -z "${catalog_suffix}" ]]; then
            error "Cannot derive the catalog suffix: global.clusterVersion is empty"
            error "and no cs-*-index-v* CatalogSources exist in openshift-marketplace."
            exit 1
        fi
        warn "Catalog suffix -${catalog_suffix} derived from live CatalogSources (clusterVersion empty)"
    fi

    local map="
redhat-operators:cs-redhat-operator-index-${catalog_suffix}
certified-operators:cs-certified-operator-index-${catalog_suffix}
community-operators:cs-community-operator-index-${catalog_suffix}
"
    local repointed=0 skipped=0 missing_catalog=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local def="${def:-}" mirror="${mirror:-}"
        def="${line%%:*}"
        mirror="${line##*:}"

        # Only repoint towards a CatalogSource that actually exists —
        # patching to a missing source leaves the subscription unresolvable
        # and is worse than leaving it on the disabled default.
        if ! oc get catalogsource "$mirror" -n openshift-marketplace >/dev/null 2>&1; then
            error "  target CatalogSource $mirror not found — $def subscriptions left untouched"
            missing_catalog=$((missing_catalog + 1))
            continue
        fi

        # One "namespace name" pair per line — read line by line, NOT
        # for-loop word splitting (which would feed each token to both
        # ns and name and patch the wrong objects).
        # Fetch the JSON explicitly: a failed oc query must not read as
        # "no subscriptions to repoint" — that would silently skip the def.
        local subs_json
        if ! subs_json=$(oc get subscriptions.operators.coreos.com -A -o json 2>/dev/null); then
            error "  cannot list subscriptions (oc query failed) — $def repoint skipped"
            continue
        fi
        local subs
        subs=$(printf '%s' "$subs_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for s in d.get('items', []):
    if s['spec'].get('source') == '$def':
        print(s['metadata']['namespace'] + ' ' + s['metadata']['name'])
" 2>/dev/null) || subs=""

        while IFS=' ' read -r ns name; do
            [[ -z "${ns:-}" ]] && continue
            # ArgoCD-owned: check both the tracking-id annotation (0.9.60
            # default) and the instance label (older label tracking) — a miss
            # patches an ArgoCD-managed subscription out of band and self-heal
            # reverts it. Fail CLOSED on unknown ownership (query/JSON error):
            # skipping is safer than a patch that would be reverted.
            local argocd_owned=""
            argocd_owned=$(oc get subscription.operators.coreos.com "$name" -n "$ns" -o json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('ERROR'); sys.exit(0)
m = d.get('metadata') or {}
labels = m.get('labels') or {}
annots = m.get('annotations') or {}
print('yes' if ('argocd.argoproj.io/instance' in labels
               or 'argocd.argoproj.io/tracking-id' in annots) else 'no')
" 2>/dev/null) || argocd_owned="ERROR"
            if [[ "$argocd_owned" == "yes" ]]; then
                info "  skipping $ns/$name (ArgoCD-owned — declarative via the airgap overlay)"
                skipped=$((skipped + 1))
                continue
            fi
            if [[ -z "$argocd_owned" || "$argocd_owned" == "ERROR" ]]; then
                warn "  cannot determine ownership of $ns/$name (query failed) — skipping to avoid an out-of-band patch ArgoCD would revert"
                skipped=$((skipped + 1))
                continue
            fi
            info "  repointing $ns/$name: $def -> $mirror"
            if oc patch subscriptions.operators.coreos.com "$name" -n "$ns" --type merge \
                -p "{\"spec\":{\"source\":\"$mirror\",\"sourceNamespace\":\"openshift-marketplace\"}}"; then
                repointed=$((repointed + 1))
            else
                error "  failed to repoint $ns/$name"
            fi
        done <<< "$subs"
    done <<< "$map"

    info "Repointed: $repointed, skipped (ArgoCD-owned or ownership unknown): $skipped, missing catalogs: $missing_catalog"

    # Final check — anything still on a disabled default catalog will never
    # resolve. Hard-fail in --repoint-subs mode (deliberate re-check); warn
    # during bootstrap, where entries skipped on purpose and day-0
    # subscriptions must not abort the run. A failed query is not a pass:
    # hard-fail in repoint mode, and no success line in bootstrap mode.
    local stragglers_json
    if ! stragglers_json=$(oc get subscriptions.operators.coreos.com -A -o json 2>/dev/null); then
        error "cannot list subscriptions for the final check (oc query failed)"
        if [[ "$MODE" == "repoint" ]]; then
            exit 1
        fi
        warn "Skipping the final default-catalog check (bootstrap mode) — re-run 'make airgap-repoint-subs' to verify"
        return 0
    fi
    local stragglers
    stragglers=$(printf '%s' "$stragglers_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for s in d.get('items', []):
    if s['spec'].get('source') in ('redhat-operators', 'certified-operators', 'community-operators'):
        print(s['metadata']['namespace'] + '/' + s['metadata']['name'] + ' -> ' + s['spec']['source'])
" 2>/dev/null) || stragglers=""
    if [[ -n "$stragglers" ]]; then
        error "Subscriptions still on disabled default catalogs:"
        while IFS= read -r s; do
            [[ -z "$s" ]] && continue
            error "  $s"
        done <<< "$stragglers"
        if [[ "$MODE" == "repoint" ]]; then
            error "ArgoCD-owned entries are declarative (airgap overlay); others need the repoint fixed."
            exit 1
        fi
        warn "Left on default catalogs during bootstrap (see above) — the pattern"
        warn "deploy may repoint or replace them; re-run 'make airgap-repoint-subs'"
        warn "after the pattern deploys to verify."
    else
        info "No subscriptions remain on disabled default catalogs"
    fi
}

# ─── Step 3e: Validate the airgap overlay's catalog references ───
# The overlay names mirrored CatalogSources literally; fail fast (before
# the pattern deploys) if any is missing, and check mirror consistency —
# a placeholder or mismatched global.mirrorRegistry would otherwise only
# surface as ImagePullBackOff inside the CVMs much later.
validate_airgap_overlay() {
    step "3e" "Validate airgap overlay catalog references"

    local overlay
    overlay=$(airgap_overlay_path)
    if [[ ! -f "$overlay" ]]; then
        warn "No airgap overlay at $overlay — skipping validation"
        return
    fi

    # This whole step is airgap-only by design ("connected works by
    # default"): unless global.airgap is true the function is inert, so a
    # connected run never aborts on airgap-only conditions (mirrored
    # catalogs absent, mirrorRegistry empty, connected-default sources).
    local airgap_flag helm_repo operator_source patterns_source
    airgap_flag=$(read_global_key global.airgap false)
    if [[ "${airgap_flag,,}" != "true" ]]; then
        return
    fi

    # Every cs-* catalog named in the overlay must exist and be READY.
    local catalogs
    catalogs=$(python3 -c "
import re, sys
text = open('${overlay}').read()
for m in sorted(set(re.findall(r'cs-[a-z-]+-index-v[0-9-]+', text))):
    print(m)
" 2>/dev/null) || catalogs=""
    local missing=0 absent=0 never_ready=0
    while IFS= read -r cs; do
        [[ -z "$cs" ]] && continue
        # Absent is a config error — count it and move on, no waiting.
        # Not-READY may just be timing: step 3 in this same run may have
        # applied the CatalogSource seconds ago, and the catalog pod pulls
        # a multi-GB index image before reporting READY.
        if ! oc get catalogsource "$cs" -n openshift-marketplace >/dev/null 2>&1; then
            error "  $cs: absent from openshift-marketplace"
            missing=$((missing + 1))
            absent=$((absent + 1))
            continue
        fi
        local state waited=0
        state=$(oc get catalogsource "$cs" -n openshift-marketplace \
            -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null) || state=""
        if [[ "$state" != "READY" ]]; then
            info "  $cs: not READY yet (state: '${state:-none}') — waiting up to 300s"
            info "  (the catalog may have been created by step 3 in this run; the"
            info "   catalog pod pulls a multi-GB index image before READY)"
            until [[ "$state" == "READY" ]] || [[ $waited -ge 300 ]]; do
                sleep 10
                waited=$((waited + 10))
                state=$(oc get catalogsource "$cs" -n openshift-marketplace \
                    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null) || state=""
            done
        fi
        if [[ "$state" == "READY" ]]; then
            if [[ $waited -gt 0 ]]; then
                info "  $cs: READY (after ${waited}s)"
            else
                info "  $cs: READY"
            fi
        else
            error "  $cs: never became READY within 300s"
            missing=$((missing + 1))
            never_ready=$((never_ready + 1))
        fi
    done <<< "$catalogs"
    if [[ $missing -gt 0 ]]; then
        error "The airgap overlay references catalogs that are either absent"
        error "from openshift-marketplace or never became READY within 300s"
        error "(absent: $absent, never READY: $never_ready)."
        error "Check that global.clusterVersion matches the mirrored operator"
        error "index tags and that step 3 applied the cs-* CatalogSources"
        error "from the oc-mirror cluster-resources."
        exit 1
    fi

    # Mirror registry consistency: global.mirrorRegistry must be a real,
    # non-placeholder value and match $MIRROR_REGISTRY (org path included).
    local mirror yaml_mirror
    mirror="${MIRROR_REGISTRY%%/}"
    yaml_mirror=$(read_global_key global.mirrorRegistry '')
    if [[ -z "$yaml_mirror" || "$yaml_mirror" == *"__MIRROR_REGISTRY__"* ]]; then
        error "global.mirrorRegistry is empty or a placeholder (__MIRROR_REGISTRY__) in values-global.yaml."
        error "Set it to the mirror root INCLUDING the org path (e.g. quay.example.com:443/mirror)"
        error "— the workload charts rewrite their images against it in airgap mode."
        exit 1
    fi
    if [[ "$yaml_mirror" != "$mirror" ]]; then
        error "global.mirrorRegistry ('$yaml_mirror') != MIRROR_REGISTRY ('$mirror')."
        error "They must be the same value (org path included) or workloads will pull"
        error "from a different registry than the one the cluster mirrors."
        exit 1
    fi
    info "global.mirrorRegistry matches MIRROR_REGISTRY ($mirror)"

    # Disconnected deploy-branch values: the connected defaults are
    # unreachable in airgap — quay.io for the Helm charts (the repo-server
    # performs no IDMS redirect) and the default operator catalogs
    # (disabled in step 2; step 3d runs before those subscriptions exist).
    # Fail fast here rather than as a stuck operator after the Pattern CR.
    local mirror_root="${MIRROR_REGISTRY%%/}"
    helm_repo=$(read_global_key main.multiSourceConfig.helmRepoUrl '')
    if [[ -z "$helm_repo" ]]; then
        error "main.multiSourceConfig.helmRepoUrl is empty while global.airgap is true."
        error "Set it to the mirror's chart path (e.g. ${mirror_root}/validatedpatterns)"
        error "on the disconnected deploy branch — the ArgoCD repo-server cannot"
        error "reach quay.io and performs no IDMS redirect."
        exit 1
    fi
    if [[ "$helm_repo" == "quay.io/validatedpatterns" ]]; then
        error "main.multiSourceConfig.helmRepoUrl is still the connected default"
        error "(quay.io/validatedpatterns) while global.airgap is true — every"
        error "chart-type application would fail at the chart-fetch stage."
        exit 1
    fi
    if [[ "$helm_repo" != "${mirror_root}"/* ]]; then
        error "main.multiSourceConfig.helmRepoUrl ('$helm_repo') is not under"
        error "MIRROR_REGISTRY ('$mirror_root') — charts would be fetched from a"
        error "different registry than the one the cluster mirrors."
        exit 1
    fi

    operator_source=$(read_global_key main.gitops.operatorSource '')
    if [[ -z "$operator_source" || "$operator_source" == "redhat-operators" ]]; then
        error "main.gitops.operatorSource is empty or still the connected default"
        error "(redhat-operators) while global.airgap is true — that catalog is"
        error "disabled in airgap. Set it to the mirrored catalog"
        error "(e.g. cs-redhat-operator-index-v5-0 for clusterVersion 5.0)."
        exit 1
    fi
    patterns_source=$(read_global_key main.patternsOperator.source '')
    if [[ -z "$patterns_source" || "$patterns_source" == "community-operators" ]]; then
        error "main.patternsOperator.source is empty or still the connected default"
        error "(community-operators) while global.airgap is true — that catalog is"
        error "disabled in airgap. Set it to the mirrored catalog"
        error "(e.g. cs-community-operator-index-v5-0 for clusterVersion 5.0)."
        exit 1
    fi
    info "Airgap values consistent: helmRepoUrl and operator sources point at the mirror"
}

# ─── Step 5: Mirror OCI Helm charts and utility images ───────────
mirror_oci_charts() {
    step 5 "Mirror OCI Helm charts and utility images"

    local imageset="${PATTERN_DIR}/airgap/imageset-config-4.22.yaml"
    if [[ ! -f "$imageset" ]]; then
        warn "No ImageSetConfiguration found at $imageset — skipping"
        return
    fi

    # OCI Helm charts (oc-mirror additionalImages can't handle these)
    info "Mirroring OCI Helm chart artifacts..."
    local charts
    charts=$(grep -E '^\s*- name: (quay\.io/validatedpatterns/|ghcr\.io/kyverno/charts/)' "$imageset" \
        | sed 's/.*- name: //' | tr -d ' ' \
        | grep -vE '(utility-container|imperative-container|pattern-ui-catalog|ubi-minimal)' || true)

    while IFS= read -r chart; do
        [[ -z "$chart" ]] && continue
        # Both quay.io and ghcr.io sources mirror under MIRROR_REGISTRY with
        # the same org/repo path (for Quay targets the org path is already
        # part of MIRROR_REGISTRY itself).
        local path_and_tag="${chart#*/}"
        local dest="${MIRROR_REGISTRY}/${path_and_tag}"
        info "  $chart → $dest"
        oc image mirror --insecure=true "$chart" "$dest" 2>&1 | tail -1 || \
            warn "  Failed (may already exist)"
    done <<< "$charts"

    # VP utility images (need both :latest and :v1)
    info "Mirroring VP utility images..."
    # pattern-ui-catalog:stable-v1 deliberately NOT mirrored — Quay rejects
    # its OCI-index manifest; see the note in airgap/imageset-config-4.22.yaml.
    for img in \
        "quay.io/validatedpatterns/utility-container:latest" \
        "quay.io/validatedpatterns/imperative-container:latest" \
        "quay.io/validatedpatterns/imperative-container:v1" \
        "registry.redhat.io/ubi9/ubi-minimal:latest"; do
        local path="${img#*/}"
        local dest="${MIRROR_REGISTRY}/${path}"
        info "  $img"
        oc image mirror --insecure=true "$img" "$dest" 2>/dev/null || \
            warn "  Failed to mirror $img"
    done

    # pattern-install chart — HARD DEPENDENCY: `pattern.sh make install`
    # resolves it from the mirror with no version pin (highest semver tag),
    # so an empty or incomplete mirror fails the deploy at chart-fetch with
    # nothing pointing back at the cause. Mirror loudly, then verify.
    local pi_dest="${MIRROR_REGISTRY}/validatedpatterns/pattern-install"
    if command -v skopeo >/dev/null 2>&1; then
        info "Mirroring pattern-install chart..."
        local pi_tags
        pi_tags=$(skopeo list-tags "docker://quay.io/validatedpatterns/pattern-install" 2>/dev/null \
            | python3 -c 'import json,sys; [print(t) for t in json.load(sys.stdin).get("Tags",[])]' 2>/dev/null || true)
        local pi_total=0 pi_failed=0
        if [[ -n "$pi_tags" ]]; then
            while IFS= read -r tag; do
                [[ -z "$tag" ]] && continue
                pi_total=$(( pi_total + 1 ))
                if ! oc image mirror --insecure=true \
                        "quay.io/validatedpatterns/pattern-install:${tag}" \
                        "${pi_dest}:${tag}" 2>/dev/null; then
                    error "  Failed to mirror pattern-install tag: ${tag}"
                    pi_failed=$(( pi_failed + 1 ))
                fi
            done <<< "$pi_tags"
            info "  Mirrored $(( pi_total - pi_failed ))/${pi_total} tags to ${pi_dest}"
        else
            warn "  Could not enumerate pattern-install tags from quay.io — verifying the mirror only"
        fi
        if [[ $pi_failed -gt 0 ]]; then
            error "pattern-install: ${pi_failed}/${pi_total} tags failed to mirror to ${pi_dest}."
            error "'pattern.sh make install' resolves this chart from the mirror"
            error "(no version pin — highest semver tag) and will fail at chart-fetch."
            exit 1
        fi
        # Verify the destination actually holds at least one tag — the
        # source-side count above is not proof the mirror is usable.
        local pi_mirror_tags
        pi_mirror_tags=$(skopeo list-tags "docker://${pi_dest}" 2>/dev/null \
            | python3 -c 'import json,sys; [print(t) for t in json.load(sys.stdin).get("Tags",[])]' 2>/dev/null || true)
        if [[ -z "$pi_mirror_tags" ]]; then
            error "pattern-install is not present in the mirror: 'skopeo list-tags"
            error "docker://${pi_dest}' returned no tags."
            error "'pattern.sh make install' resolves this chart from the mirror"
            error "(no version pin — highest semver tag) and will fail at chart-fetch."
            exit 1
        fi
        info "  pattern-install present in mirror ($(echo "$pi_mirror_tags" | wc -l | tr -d ' ') tags)"
    else
        warn "  skopeo not available — cannot verify that pattern-install is mirrored"
        warn "  to ${pi_dest}. 'pattern.sh make install' resolves this chart from"
        warn "  the mirror and WILL FAIL at chart-fetch if it is not already there."
    fi

    info "OCI mirroring complete"
}

# ─── Step 6: Fix oc-mirror manifest list failures ────────────────
fix_manifest_lists() {
    step 6 "Fix oc-mirror manifest list failures"

    local workspace="${HOME}/oc-mirror-workspace"
    local error_log
    error_log=$(ls -t "${workspace}/working-dir/logs/mirroring_errors_"*.txt 2>/dev/null | head -1 || true)

    if [[ -z "$error_log" ]] || [[ ! -f "$error_log" ]]; then
        info "No mirroring error log found — skipping"
        return
    fi

    local failed_images
    failed_images=$(grep -oP 'docker://\S+' "$error_log" | sed 's/docker:\/\///' | sort -u || true)

    if [[ -z "$failed_images" ]]; then
        info "No failed images in error log — skipping"
        return
    fi

    warn "Found $(echo "$failed_images" | wc -l | tr -d ' ') failed images from oc-mirror"

    while IFS= read -r img; do
        [[ -z "$img" ]] && continue
        local src_registry="${img%%/*}"
        local path_tag="${img#*/}"
        # Strip digest for tag-based fallback
        local path_notag="${path_tag%%@*}"
        local dest="${MIRROR_REGISTRY}/${path_notag}"

        info "  Fixing: $img"

        # Try 1: oc image mirror with --keep-manifest-list (preserves multi-arch)
        if oc image mirror --insecure=true --keep-manifest-list=true "$img" "$dest" 2>/dev/null; then
            info "    OK (manifest list preserved)"
            continue
        fi

        # Try 2: oc image mirror with --filter-by-os (single arch, tag-based)
        local tag_img="${path_notag##*/}"
        local tag_base="${img%%@*}"
        if [[ "$tag_base" != "$img" ]]; then
            # Has a digest — try by-tag equivalent
            local repo_path="${path_notag%/*}"
            # Mirror the tag version instead
            info "    Fallback: mirroring by tag"
            oc image mirror --insecure=true --filter-by-os="linux/amd64" \
                "${tag_base}:latest" "${dest}:latest" 2>/dev/null || \
                warn "    Tag-based fallback also failed"
        fi
    done <<< "$failed_images"
}

# ─── Step 8: Enable OVN routingViaHost (opt-in, test-lab only) ───
enable_routing_via_host() {
    step 8 "OVN routingViaHost (test-lab only)"

    if [[ "${ENABLE_ROUTINGVIAHOST:-}" != "true" ]]; then
        info "Skipped (set ENABLE_ROUTINGVIAHOST=true to enable)"
        return
    fi

    local current
    current=$(oc get network.operator cluster \
        -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}' 2>/dev/null || echo "")
    if [[ "$current" == "true" ]]; then
        info "Already enabled — skipping"
        return
    fi

    warn "Enabling routingViaHost — this may cause a brief network disruption"
    oc patch network.operator cluster --type merge \
        -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}'
    info "routingViaHost enabled"
}

# ─── Step 9: Set up git HTTP server ─────────────────────────────
setup_git_server() {
    step 9 "Set up smart HTTP git server"

    mkdir -p "$GIT_REPO_ROOT"

    # Auto-detect repos
    local repos=()
    if [[ -n "${GIT_REPOS:-}" ]]; then
        read -ra repos <<< "$GIT_REPOS"
    else
        for candidate in \
            "${HOME}/coco-pattern" \
            "${HOME}/trustee-chart" \
            "${HOME}/sandboxed-containers-chart" \
            "${HOME}/sandboxed-policies-chart"; do
            [[ -d "$candidate/.git" ]] && repos+=("$candidate")
        done
    fi

    if [[ ${#repos[@]} -eq 0 ]]; then
        warn "No git repos found to serve"
        return
    fi

    # Create/update bare repos
    for repo_path in "${repos[@]}"; do
        local repo_name
        repo_name=$(basename "$repo_path")
        local bare_path="${GIT_REPO_ROOT}/${repo_name}.git"

        if [[ -d "$bare_path" ]]; then
            info "Syncing: $repo_name"
            local branch
            branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
            git -C "$repo_path" push "$bare_path" "$branch" --force 2>/dev/null || true
        else
            info "Creating bare repo: $repo_name"
            git clone --bare --no-hardlinks "$repo_path" "$bare_path"
        fi
        git -C "$bare_path" update-server-info
    done

    # SELinux + permissions
    command -v restorecon >/dev/null 2>&1 && restorecon -R "$GIT_REPO_ROOT/"
    chmod -R a+rX "$GIT_REPO_ROOT/"
    find "$GIT_REPO_ROOT/" -type f -exec chmod a+r {} \;

    # Start smart HTTP server (go-git can't handle dumb HTTP from Apache)
    local server_script="${SCRIPT_DIR}/git-http-server.py"
    if [[ ! -f "$server_script" ]]; then
        warn "git-http-server.py not found at $server_script"
        return
    fi

    # Check if already running
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${GIT_HTTP_PORT}/coco-pattern.git/info/refs?service=git-upload-pack" 2>/dev/null | grep -q 200; then
        info "Smart HTTP server already running on port $GIT_HTTP_PORT"
    else
        # Try systemd user service first
        if systemctl --user is-enabled git-http.service >/dev/null 2>&1; then
            systemctl --user restart git-http.service
            info "Restarted git-http systemd service"
        else
            # Create and start systemd service
            mkdir -p ~/.config/systemd/user
            cat > ~/.config/systemd/user/git-http.service <<SVCEOF
[Unit]
Description=Git Smart HTTP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${server_script} ${GIT_HTTP_PORT} ${GIT_REPO_ROOT}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
SVCEOF
            systemctl --user daemon-reload
            systemctl --user enable --now git-http.service
            info "Started git-http systemd service on port $GIT_HTTP_PORT"
        fi
    fi

    # Report URLs — use the DNS name (FR-017): the node resolves it via lab DNS
    # (the ignition's resolver), so a host address change does not break pulls.
    local host_name
    host_name=$(hostname -f 2>/dev/null || echo "JUMP_HOST_DNS")
    info ""
    info "Git HTTP URLs:"
    for repo_path in "${repos[@]}"; do
        local repo_name
        repo_name=$(basename "$repo_path")
        info "  http://${host_name}:${GIT_HTTP_PORT}/${repo_name}.git"
    done
}

# ─── Step 10: Create patterns-operator-config ConfigMap ──────────
create_operator_config() {
    step 10 "Create patterns-operator-config ConfigMap"

    # Read gitops channel from values-global.yaml
    local gitops_channel
    gitops_channel=$(read_global_key main.gitops.channel gitops-1.22)

    local gitops_source
    # operatorSource may be empty in connected mode — fall back to a
    # clusterVersion-derived mirrored catalog name (same convention as the
    # overlay and step 3d), never a hardcoded minor.
    local cluster_version default_source
    cluster_version=$(read_global_key global.clusterVersion '')
    local catalog_suffix
    if [[ -n "$cluster_version" ]]; then
        catalog_suffix="v${cluster_version//./-}"
    else
        # Same fallback as step 3d: derive from the CatalogSources oc-mirror
        # actually created, never a hardcoded minor.
        catalog_suffix=$(oc get catalogsources -n openshift-marketplace \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
            | grep -oE 'index-v[0-9]+-[0-9]+' | head -1 | sed 's/.*index-//' || true)
    fi
    if [[ -z "$catalog_suffix" ]]; then
        error "Cannot derive the GitOps catalog source: global.clusterVersion is empty"
        error "and no cs-*-index-v* CatalogSources exist in openshift-marketplace."
        exit 1
    fi
    default_source="cs-redhat-operator-index-${catalog_suffix}"
    # Absent key OR present-but-empty both fall back to the derived default
    # (the old inline read used `... or default`, so an explicit empty string
    # must not reach the ConfigMap either).
    gitops_source=$(read_global_key main.gitops.operatorSource '')
    gitops_source="${gitops_source:-$default_source}"

    info "GitOps channel: $gitops_channel (from values-global.yaml)"
    info "GitOps source: $gitops_source"

    cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: patterns-operator-config
  namespace: openshift-operators
data:
  gitops.channel: "${gitops_channel}"
  gitops.catalogSource: "${gitops_source}"
  gitops.sourceNamespace: "openshift-marketplace"
  # App-of-apps sync-wave gating (Application health check) — see
  # argoproj/argo-cd#3781; without it the root app applies all waves ungated.
  # The connected path sets it declaratively (values-global.yaml) once
  # pattern-install renders it (pattern-install-chart#53); this bootstrap
  # writes it directly — the operator subscription predates chart renders.
  gitops.applicationHealthCheckEnabled: "true"
EOF
    info "patterns-operator-config ConfigMap created"

    # Post-apply assertion: the operator only restores the Application health
    # check when the key is present at its first reconcile — fail loudly here
    # rather than let the root app apply all waves ungated.
    local key
    key=$(oc get configmap patterns-operator-config -n openshift-operators \
        -o jsonpath='{.data.gitops\.applicationHealthCheckEnabled}' 2>/dev/null || true)
    if [[ "$key" != "true" ]]; then
        error "gitops.applicationHealthCheckEnabled is not \"true\" on patterns-operator-config"
        exit 1
    fi
    info "Application health check key verified on patterns-operator-config"
}

# ─── Step 11: Deploy Pattern CR directly ─────────────────────────
deploy_pattern_cr() {
    step 11 "Deploy Pattern CR"

    # Read values from values-global.yaml
    # Multi-key read in one pass is intentional (emits several assignments) —
    # not converted to read_global_key.
    local cluster_group repo_url revision helm_repo_url chart_version
    eval "$(python3 -c "
import yaml
with open('${PATTERN_DIR}/values-global.yaml') as f:
    d = yaml.safe_load(f)
    m = d.get('main', {})
    print(f'cluster_group=\"{m.get(\"clusterGroupName\", \"baremetal\")}\"')
    print(f'repo_url=\"{m.get(\"git\", {}).get(\"repoURL\", \"\")}\"')
    print(f'revision=\"{m.get(\"git\", {}).get(\"revision\", \"main\")}\"')
    print(f'helm_repo_url=\"{m.get(\"multiSourceConfig\", {}).get(\"helmRepoUrl\", \"\")}\"')
    print(f'chart_version=\"{m.get(\"multiSourceConfig\", {}).get(\"clusterGroupChartVersion\", \"0.9.*\")}\"')
" 2>/dev/null)"

    if [[ -z "$repo_url" ]]; then
        error "git.repoURL not set in values-global.yaml"
        return
    fi

    info "Deploying Pattern CR:"
    info "  clusterGroupName: $cluster_group"
    info "  targetRepo: $repo_url"
    info "  targetRevision: $revision"
    info "  helmRepoUrl: $helm_repo_url"

    cat <<EOF | oc apply -f -
apiVersion: gitops.hybrid-cloud-patterns.io/v1alpha1
kind: Pattern
metadata:
  name: coco-pattern
  namespace: openshift-operators
spec:
  clusterGroupName: ${cluster_group}
  gitSpec:
    targetRepo: ${repo_url}
    targetRevision: ${revision}
  multiSourceConfig:
    enabled: true
    helmRepoUrl: ${helm_repo_url}
    clusterGroupChartVersion: "${chart_version}"
EOF
    info "Pattern CR deployed"
}

# ─── Sync-only mode ─────────────────────────────────────────────
sync_repos() {
    info "Syncing working copies to bare HTTP repos"

    local repos=()
    if [[ -n "${GIT_REPOS:-}" ]]; then
        read -ra repos <<< "$GIT_REPOS"
    else
        for candidate in \
            "${HOME}/coco-pattern" \
            "${HOME}/trustee-chart" \
            "${HOME}/sandboxed-containers-chart" \
            "${HOME}/sandboxed-policies-chart"; do
            [[ -d "$candidate/.git" ]] && repos+=("$candidate")
        done
    fi

    for repo_path in "${repos[@]}"; do
        local repo_name
        repo_name=$(basename "$repo_path")
        local bare_path="${GIT_REPO_ROOT}/${repo_name}.git"

        if [[ ! -d "$bare_path" ]]; then
            warn "$bare_path does not exist — run without --sync-repos-only first"
            continue
        fi

        local branch
        branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
        info "Pushing $repo_name ($branch) → $bare_path"
        git -C "$repo_path" push "$bare_path" "$branch" --force 2>&1 || \
            warn "  Push failed"
        git -C "$bare_path" update-server-info
    done

    command -v restorecon >/dev/null 2>&1 && restorecon -R "$GIT_REPO_ROOT/"
    chmod -R a+rX "$GIT_REPO_ROOT/"
    info "Sync complete"
}

# ─── Main ────────────────────────────────────────────────────────
case "$MODE" in
    sync)
        sync_repos
        exit 0
        ;;
    deploy)
        validate_prereqs
        create_operator_config
        deploy_pattern_cr
        # Helm OCI auth skipped — Quay repos are public (ANONYMOUS_ACCESS: true).
        # Mounting pull-secret as HELM_REGISTRY_CONFIG causes 401 errors.
        exit 0
        ;;
    fix-manifests)
        validate_prereqs
        fix_manifest_lists
        exit 0
        ;;
    repoint)
        # Standalone safety net — safe to run any time after the bootstrap,
        # e.g. once MCH has created its runtime subscriptions.
        validate_prereqs
        repoint_default_catalog_subscriptions
        exit 0
        ;;
esac

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  CoCo Pattern — Disconnected Post-Install Bootstrap         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

validate_prereqs
disable_default_catalogs
create_catalog_sources
apply_ocmirror_resources
normalise_mirror_source_policy
repoint_default_catalog_subscriptions
validate_airgap_overlay
mirror_oci_charts
fix_manifest_lists
# Step 7 (argocd-tls-certs-cm) removed — it was a silent no-op (ran before
# the vp-gitops namespace existed); do not re-add. The mirror CA reaches the
# repo-server only after the proxy/cluster trustedCA patch — still manual,
# see DEPLOY-RUNBOOK.md C-3 (#171). Step 7b never ran: mirror chart repos
# are public (ANONYMOUS_ACCESS); a pull-secret HELM_REGISTRY_CONFIG 401'd.
enable_routing_via_host
setup_git_server
create_operator_config

echo ""
info "Post-install bootstrap complete."
info ""
info "Next steps:"
info "  1. Wait for patterns-operator to install via OLM (~2 min)"
info "  2. Deploy the pattern:"
info "     make airgap-deploy-pattern"
info "  3. Wait for ArgoCD apps to sync (~10 min)"
info "  4. Load secrets into Vault:"
info "     ./pattern.sh make load-secrets"
