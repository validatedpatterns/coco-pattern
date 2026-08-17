#!/usr/bin/env bash
# Post-install bootstrap for disconnected CoCo pattern deployment.
# Run after oc-mirror completes and before deploying the pattern.
#
# Idempotent — safe to re-run. Each step checks current state before acting.
#
# Required env:
#   KUBECONFIG          — path to cluster kubeconfig
#   MIRROR_REGISTRY     — registry host:port (e.g. MIRROR_REGISTRY_HOST:8443)
#
# Optional env:
#   EXTRA_CA_CERT           — path to CA cert file for the mirror registry
#   GIT_HTTP_PORT           — port for smart HTTP git server (default: 8080)
#   GIT_REPO_ROOT           — path to bare git repos (default: ~/public_html/git)
#   GIT_REPOS               — space-separated list of working copy dirs to serve
#   ENABLE_ROUTINGVIAHOST   — set to "true" to enable OVN routingViaHost (test-lab only)
#
# Modes:
#   (no args)             — run all steps
#   --sync-repos-only     — only sync working copies to bare HTTP repos
#   --deploy-pattern      — deploy the Pattern CR directly (skip pattern.sh)
#   --fix-manifest-lists  — fix oc-mirror manifest list failures with skopeo

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

# ─── Mode dispatch ───────────────────────────────────────────────
MODE="full"
case "${1:-}" in
    --sync-repos-only)    MODE="sync"; shift ;;
    --deploy-pattern)     MODE="deploy"; shift ;;
    --fix-manifest-lists) MODE="fix-manifests"; shift ;;
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
        error "MIRROR_REGISTRY is not set (e.g. MIRROR_REGISTRY_HOST:8443)"
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
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local manual_itms="${script_dir}/../airgap/itms-manual-mirrors.yaml"
    if [[ -f "$manual_itms" ]]; then
        info "  Applying manual ITMS: $(basename "$manual_itms") with NeverContactSource policy"
        python3 -c "
import sys, yaml
docs = list(yaml.safe_load_all(open('$manual_itms')))
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
" 2>/tmp/idms_status)
        local status; status=$(cat /tmp/idms_status)
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
" 2>/tmp/itms_status)
        local status; status=$(cat /tmp/itms_status)
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

# ─── Step 5: Mirror OCI Helm charts and utility images ───────────
mirror_oci_charts() {
    step 5 "Mirror OCI Helm charts and utility images"

    local imageset="${PATTERN_DIR}/airgap/imageset-config.yaml"
    if [[ ! -f "$imageset" ]]; then
        warn "No imageset-config.yaml found at $imageset — skipping"
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
        local src_registry="${chart%%/*}"
        local path_and_tag="${chart#*/}"
        local dest
        if [[ "$src_registry" == "quay.io" ]]; then
            dest="${MIRROR_REGISTRY}/${path_and_tag}"
        else
            dest="${MIRROR_REGISTRY}/${path_and_tag}"
        fi
        info "  $chart → $dest"
        oc image mirror --insecure=true "$chart" "$dest" 2>&1 | tail -1 || \
            warn "  Failed (may already exist)"
    done <<< "$charts"

    # VP utility images (need both :latest and :v1)
    info "Mirroring VP utility images..."
    for img in \
        "quay.io/validatedpatterns/utility-container:latest" \
        "quay.io/validatedpatterns/imperative-container:latest" \
        "quay.io/validatedpatterns/imperative-container:v1" \
        "quay.io/validatedpatterns/pattern-ui-catalog:stable-v1" \
        "registry.redhat.io/ubi9/ubi-minimal:latest"; do
        local path="${img#*/}"
        local dest="${MIRROR_REGISTRY}/${path}"
        info "  $img"
        oc image mirror --insecure=true "$img" "$dest" 2>/dev/null || \
            warn "  Failed to mirror $img"
    done

    # pattern-install chart (all tags if skopeo available)
    if command -v skopeo >/dev/null 2>&1; then
        info "Mirroring pattern-install chart..."
        local pi_tags
        pi_tags=$(skopeo list-tags "docker://quay.io/validatedpatterns/pattern-install" 2>/dev/null \
            | python3 -c 'import json,sys; [print(t) for t in json.load(sys.stdin).get("Tags",[])]' 2>/dev/null || true)
        if [[ -n "$pi_tags" ]]; then
            while IFS= read -r tag; do
                [[ -z "$tag" ]] && continue
                oc image mirror --insecure=true \
                    "quay.io/validatedpatterns/pattern-install:${tag}" \
                    "${MIRROR_REGISTRY}/validatedpatterns/pattern-install:${tag}" 2>/dev/null || true
            done <<< "$pi_tags"
            info "  Mirrored $(echo "$pi_tags" | wc -l | tr -d ' ') tags"
        fi
    else
        warn "  skopeo not available — skipping pattern-install tag enumeration"
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

# ─── Step 7: Add extra CA certificate to ArgoCD ──────────────────
add_argocd_ca() {
    step 7 "Add extra CA certificate to ArgoCD"

    if [[ -z "${EXTRA_CA_CERT:-}" ]]; then
        # Try to extract from cluster's additionalTrustBundle
        local cluster_ca
        cluster_ca=$(oc get cm user-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || true)
        if [[ -n "$cluster_ca" ]]; then
            info "Using CA from cluster's additionalTrustBundle"
            echo "$cluster_ca" > /tmp/mirror-ca.crt
            EXTRA_CA_CERT="/tmp/mirror-ca.crt"
        else
            info "No EXTRA_CA_CERT and no cluster CA bundle — skipping"
            return
        fi
    fi

    if [[ ! -f "$EXTRA_CA_CERT" ]]; then
        error "CA cert file not found: $EXTRA_CA_CERT"
        return
    fi

    local registry_host="${MIRROR_REGISTRY%%:*}"

    # Apply to all ArgoCD namespaces that exist
    for ns in vp-gitops openshift-gitops; do
        if ! oc get namespace "$ns" >/dev/null 2>&1; then
            continue
        fi
        oc create configmap argocd-tls-certs-cm -n "$ns" \
            --from-file="${registry_host}=${EXTRA_CA_CERT}" \
            --dry-run=client -o yaml | oc apply -f - 2>/dev/null
        info "CA cert added to argocd-tls-certs-cm in $ns"
    done
}

# ─── Step 7b: Configure ArgoCD Helm OCI registry auth ────────────
configure_argocd_helm_auth() {
    step "7b" "Configure ArgoCD Helm OCI registry auth"

    local registry_base="${MIRROR_REGISTRY%%/mirror*}"

    # Check if ArgoCD namespace exists
    local argocd_ns=""
    for ns in vp-gitops openshift-gitops; do
        if oc get namespace "$ns" >/dev/null 2>&1; then
            argocd_ns="$ns"
            break
        fi
    done

    if [[ -z "$argocd_ns" ]]; then
        warn "No ArgoCD namespace yet — run this step again after Pattern CR is deployed"
        return
    fi

    # Create docker config secret from the cluster's pull-secret
    local pull_secret_json
    pull_secret_json=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d || true)

    if [[ -z "$pull_secret_json" ]]; then
        warn "Could not read cluster pull-secret — using local pull-secret.json"
        if [[ -f "${HOME}/pull-secret.json" ]]; then
            pull_secret_json=$(cat "${HOME}/pull-secret.json")
        else
            warn "No pull-secret found — ArgoCD may not be able to pull from private OCI repos"
            return
        fi
    fi

    # Create the helm registry config secret
    oc create secret generic helm-registry-config -n "$argocd_ns" \
        --from-literal=config.json="$pull_secret_json" \
        --dry-run=client -o yaml | oc apply -f - 2>/dev/null
    info "Helm registry config secret created in $argocd_ns"

    # Patch ArgoCD CR to mount docker config for Helm OCI auth
    # HELM_REGISTRY_CONFIG tells Helm where to find registry credentials
    if oc get argocd -n "$argocd_ns" -o name >/dev/null 2>&1; then
        local argocd_name
        argocd_name=$(oc get argocd -n "$argocd_ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "$argocd_name" ]]; then
            oc patch argocd "$argocd_name" -n "$argocd_ns" --type merge -p '
spec:
  repo:
    env:
    - name: HELM_REGISTRY_CONFIG
      value: /tmp/helm-config/config.json
    volumes:
    - name: helm-registry-config
      secret:
        secretName: helm-registry-config
    volumeMounts:
    - name: helm-registry-config
      mountPath: /tmp/helm-config
      readOnly: true
' 2>/dev/null
            info "ArgoCD $argocd_name patched with Helm OCI registry auth"
        fi
    else
        warn "No ArgoCD CR found yet — will need to patch after Pattern CR creates it"
    fi
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

    # Report URLs
    local host_ip
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "JUMP_HOST_IP")
    info ""
    info "Git HTTP URLs:"
    for repo_path in "${repos[@]}"; do
        local repo_name
        repo_name=$(basename "$repo_path")
        info "  http://${host_ip}:${GIT_HTTP_PORT}/${repo_name}.git"
    done
}

# ─── Step 10: Create patterns-operator-config ConfigMap ──────────
create_operator_config() {
    step 10 "Create patterns-operator-config ConfigMap"

    local registry_base="${MIRROR_REGISTRY%%/mirror*}"

    # Read gitops channel from values-global.yaml
    local gitops_channel
    gitops_channel=$(python3 -c "
import yaml
with open('${PATTERN_DIR}/values-global.yaml') as f:
    d = yaml.safe_load(f)
    print(d.get('main',{}).get('gitops',{}).get('channel','latest'))
" 2>/dev/null || echo "latest")

    local gitops_source
    gitops_source=$(python3 -c "
import yaml
with open('${PATTERN_DIR}/values-global.yaml') as f:
    d = yaml.safe_load(f)
    print(d.get('main',{}).get('gitops',{}).get('operatorSource','cs-redhat-operator-index-v4-21'))
" 2>/dev/null || echo "cs-redhat-operator-index-v4-21")

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
EOF
    info "patterns-operator-config ConfigMap created"
}

# ─── Step 11: Deploy Pattern CR directly ─────────────────────────
deploy_pattern_cr() {
    step 11 "Deploy Pattern CR"

    # Read values from values-global.yaml
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
        info ""
        info "Waiting 30s for ArgoCD to be created by patterns-operator..."
        sleep 30
        add_argocd_ca
        # Helm OCI auth skipped — Quay repos are public (ANONYMOUS_ACCESS: true).
        # Mounting pull-secret as HELM_REGISTRY_CONFIG causes 401 errors.
        exit 0
        ;;
    fix-manifests)
        validate_prereqs
        fix_manifest_lists
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
mirror_oci_charts
fix_manifest_lists
add_argocd_ca
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
