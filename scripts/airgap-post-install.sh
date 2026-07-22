#!/usr/bin/env bash
# Post-install bootstrap for disconnected CoCo pattern deployment.
# Run after oc-mirror completes and before `make install`.
#
# Idempotent — safe to re-run. Each step checks current state before acting.
#
# Required env:
#   KUBECONFIG          — path to cluster kubeconfig
#   MIRROR_REGISTRY     — registry host:port/path (e.g. quay.apac-tech-lab.net:443/mirror)
#
# Optional env:
#   EXTRA_CA_CERT           — path to CA cert file for the mirror registry
#   GIT_REPO_ROOT           — path to bare git repos (default: ~/public_html/git)
#   GIT_REPOS               — space-separated list of working copy dirs to serve
#                             (default: auto-detect from ~/coco-pattern and ~/trustee-chart etc.)
#   ENABLE_ROUTINGVIAHOST   — set to "true" to enable OVN routingViaHost
#                             (APAC lab workaround — not needed on properly routed networks)
#
# Modes:
#   (no args)           — run all steps
#   --sync-repos-only   — only sync working copies to bare HTTP repos

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GIT_REPO_ROOT="${GIT_REPO_ROOT:-${HOME}/public_html/git}"
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
if [[ "${1:-}" == "--sync-repos-only" ]]; then
    SYNC_ONLY=true
    shift
else
    SYNC_ONLY=false
fi

# ─── Step 1: Validate prerequisites ─────────────────────────────
validate_prereqs() {
    step 1 "Validate prerequisites"

    local missing=()
    for cmd in oc git skopeo; do
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
        error "MIRROR_REGISTRY is not set (e.g. quay.example.com:443/mirror)"
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
        return
    fi

    oc patch OperatorHub cluster --type json \
        -p '[{"op":"add","path":"/spec/disableAllDefaultSources","value":true}]'
    info "Default CatalogSources disabled"

    info "Remaining catalogs:"
    oc get catalogsource -n openshift-marketplace --no-headers 2>/dev/null || true
}

# ─── Step 3: Mirror OCI Helm charts ─────────────────────────────
mirror_oci_charts() {
    step 3 "Mirror OCI Helm charts"

    local imageset="${PATTERN_DIR}/airgap/imageset-config.yaml"
    if [[ ! -f "$imageset" ]]; then
        warn "No imageset-config.yaml found at $imageset — skipping OCI chart mirroring"
        return
    fi

    local registry_host="${MIRROR_REGISTRY%%/*}"

    # Extract VP charts from imageset-config (quay.io/validatedpatterns/* entries)
    local vp_charts
    vp_charts=$(grep -E '^\s*- name: quay\.io/validatedpatterns/' "$imageset" \
        | sed 's/.*- name: //' | tr -d ' ' || true)

    # Extract Kyverno chart
    local kyverno_charts
    kyverno_charts=$(grep -E '^\s*- name: ghcr\.io/kyverno/charts/' "$imageset" \
        | sed 's/.*- name: //' | tr -d ' ' || true)

    # Mirror VP charts
    if [[ -n "$vp_charts" ]]; then
        info "Mirroring VP Helm OCI charts..."
        while IFS= read -r chart; do
            [[ -z "$chart" ]] && continue
            local name="${chart#quay.io/}"
            local dest="${MIRROR_REGISTRY}/${name#mirror/}"
            info "  $chart → $dest"
            oc image mirror --insecure=true "$chart" "$dest" 2>&1 | tail -1 || \
                warn "  Failed to mirror $chart (may already exist)"
        done <<< "$vp_charts"
    fi

    # Mirror Kyverno chart
    if [[ -n "$kyverno_charts" ]]; then
        info "Mirroring Kyverno Helm OCI charts..."
        while IFS= read -r chart; do
            [[ -z "$chart" ]] && continue
            local name="${chart#ghcr.io/}"
            local dest="${MIRROR_REGISTRY}/${name}"
            info "  $chart → $dest"
            oc image mirror --insecure=true "$chart" "$dest" 2>&1 | tail -1 || \
                warn "  Failed to mirror $chart (may already exist)"
        done <<< "$kyverno_charts"
    fi

    # Mirror pattern-install (all tags)
    info "Mirroring pattern-install chart (all tags)..."
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
        info "  Mirrored $(echo "$pi_tags" | wc -l) tags"
    else
        warn "  Could not list pattern-install tags (internet access required)"
    fi

    # Mirror :latest tags that oc-mirror sometimes misses
    info "Mirroring :latest tags for VP utility images..."
    for img in \
        "quay.io/validatedpatterns/utility-container:latest" \
        "quay.io/validatedpatterns/imperative-container:latest" \
        "registry.redhat.io/ubi9/ubi-minimal:latest"; do
        local dest_path="${img#*/}"
        dest_path="${dest_path%%:*}"
        local dest_tag="${img##*:}"
        oc image mirror --insecure=true "$img" "${MIRROR_REGISTRY}/${dest_path}:${dest_tag}" 2>/dev/null || \
            warn "  Failed to mirror $img"
    done
    info "OCI chart mirroring complete"
}

# ─── Step 4: Add extra CA certificate to ArgoCD ─────────────────
add_argocd_ca() {
    step 4 "Add extra CA certificate to ArgoCD"

    if [[ -z "${EXTRA_CA_CERT:-}" ]]; then
        info "EXTRA_CA_CERT not set — skipping"
        info "If ArgoCD shows TLS errors for $MIRROR_REGISTRY, set EXTRA_CA_CERT to the CA cert path"
        return
    fi
    if [[ ! -f "$EXTRA_CA_CERT" ]]; then
        error "CA cert file not found: $EXTRA_CA_CERT"
        return
    fi

    local registry_host="${MIRROR_REGISTRY%%:*}"
    # ArgoCD namespace may be vp-gitops (patterns-operator) or openshift-gitops
    local argocd_ns=""
    for ns in vp-gitops openshift-gitops; do
        if oc get namespace "$ns" >/dev/null 2>&1; then
            argocd_ns="$ns"
            break
        fi
    done

    if [[ -z "$argocd_ns" ]]; then
        warn "No ArgoCD namespace found yet (vp-gitops or openshift-gitops)"
        warn "Run this script again after 'make install' creates the ArgoCD namespace"
        return
    fi

    # Check if CM already has the cert
    local existing
    existing=$(oc get cm argocd-tls-certs-cm -n "$argocd_ns" \
        -o jsonpath="{.data.${registry_host}}" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        info "CA cert for $registry_host already in argocd-tls-certs-cm — skipping"
        return
    fi

    oc create configmap argocd-tls-certs-cm -n "$argocd_ns" \
        --from-file="${registry_host}=${EXTRA_CA_CERT}" \
        --dry-run=client -o yaml | oc apply -f -
    info "Added CA cert for $registry_host to argocd-tls-certs-cm in $argocd_ns"
}

# ─── Step 5: Enable OVN routingViaHost (opt-in) ─────────────────
enable_routing_via_host() {
    step 5 "OVN routingViaHost"

    if [[ "${ENABLE_ROUTINGVIAHOST:-}" != "true" ]]; then
        info "Skipped (set ENABLE_ROUTINGVIAHOST=true to enable)"
        info "This is only needed when pods must reach hosts on subnets"
        info "that the OVN default gateway cannot route to (e.g. APAC lab)."
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

# ─── Step 6: Create bare git repos for HTTP serving ──────────────
setup_git_repos() {
    step 6 "Create bare git repos for HTTP serving"

    mkdir -p "$GIT_REPO_ROOT"

    # Auto-detect repos or use GIT_REPOS env
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

    for repo_path in "${repos[@]}"; do
        local repo_name
        repo_name=$(basename "$repo_path")
        local bare_path="${GIT_REPO_ROOT}/${repo_name}.git"

        if [[ -d "$bare_path" ]]; then
            info "Updating existing bare repo: $repo_name"
            local branch
            branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
            git -C "$repo_path" push "$bare_path" "$branch" 2>/dev/null || \
                warn "  Push failed for $repo_name (may need force push)"
        else
            info "Creating bare repo: $repo_name"
            git clone --bare --no-hardlinks "$repo_path" "$bare_path"
        fi
        git -C "$bare_path" update-server-info
    done

    # Fix SELinux contexts (critical for Apache UserDir serving)
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R "$GIT_REPO_ROOT/"
        info "SELinux contexts fixed"
    fi

    # Fix permissions
    chmod -R a+rX "$GIT_REPO_ROOT/"
    find "$GIT_REPO_ROOT/" -type f -exec chmod a+r {} \;

    info "Bare repos ready at $GIT_REPO_ROOT"
    info ""
    info "HTTP URLs for values-global.yaml:"
    local host_ip
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "JUMP_HOST_IP")
    local user
    user=$(whoami)
    for repo_path in "${repos[@]}"; do
        local repo_name
        repo_name=$(basename "$repo_path")
        info "  http://${host_ip}/~${user}/git/${repo_name}.git"
    done
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
        git -C "$repo_path" push "$bare_path" "$branch" 2>&1 || \
            warn "  Push failed (may need: git -C $repo_path push $bare_path $branch --force)"
        git -C "$bare_path" update-server-info
    done

    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R "$GIT_REPO_ROOT/"
    fi
    chmod -R a+rX "$GIT_REPO_ROOT/"

    info "Sync complete"
}

# ─── Main ────────────────────────────────────────────────────────
if [[ "$SYNC_ONLY" == "true" ]]; then
    sync_repos
    exit 0
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  CoCo Pattern — Disconnected Post-Install Bootstrap         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

validate_prereqs
disable_default_catalogs
mirror_oci_charts
add_argocd_ca
enable_routing_via_host
setup_git_repos

echo ""
info "Post-install bootstrap complete."
info ""
info "Next steps:"
info "  1. Update values-global.yaml git.repoURL to the HTTP URL above"
info "  2. Run: make install"
info "  3. After ArgoCD namespace exists, re-run to add CA cert:"
info "     EXTRA_CA_CERT=/path/to/ca.crt $0"
