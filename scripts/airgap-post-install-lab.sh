#!/usr/bin/env bash
# APAC-lab wrapper for the disconnected post-install bootstrap.
#
# NOT part of the generic pattern flow. The qualification lab fakes its
# airgap (see airgap/DEPLOY-RUNBOOK.md, Appendix B) and keeps a fixed
# checkout layout; this wrapper adds exactly those two lab specifics on
# top of the generic script, which owns everything any disconnected
# deployment needs:
#
#   1. Faked airgap (category 1): OVN routingViaHost. The lab enforces
#      disconnection at the pod boundary, so pod traffic leaves via the
#      node host network. Applied BEFORE the generic bootstrap — the
#      catalog pods created by it pull multi-GB index images through
#      that route. Idempotent; opt out with ENABLE_ROUTINGVIAHOST=false.
#
#   2. Lab checkout layout (category 3): serve the lab's four working
#      copies over the git HTTP server instead of just the pattern repo
#      (the generic default). Override with GIT_REPOS.
#
# A genuinely airgapped site must run scripts/airgap-post-install.sh
# directly and must NOT need anything in this file.
#
# Required env: KUBECONFIG, MIRROR_REGISTRY (see the generic script).
#
# Usage: scripts/airgap-post-install-lab.sh [mode flags of the generic
#        script — routingViaHost is only applied for the full bootstrap]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The lab needs host routing in its faked airgap; opt-in elsewhere became
# opt-out here because this wrapper exists only for that lab.
ENABLE_ROUTINGVIAHOST="${ENABLE_ROUTINGVIAHOST:-true}"
export ENABLE_ROUTINGVIAHOST

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${GREEN}===${NC} Step $1: $2 ${GREEN}===${NC}"; }

# ─── Lab step 8: OVN routingViaHost (faked-airgap pod egress) ────
# Moved verbatim from the generic script (PR #174 review comment 13):
# only environments that fake disconnection at the pod boundary need
# off-cluster egress via the node host network.
enable_routing_via_host() {
    step 8 "OVN routingViaHost (lab faked-airgap egress)"

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

# ─── Lab checkout layout ─────────────────────────────────────────
# The lab's deploy host keeps the pattern and the external-chart
# checkouts directly under $HOME. Only existing checkouts are served.
if [[ -z "${GIT_REPOS:-}" ]]; then
    lab_repos=()
    for candidate in \
        "${HOME}/coco-pattern" \
        "${HOME}/trustee-chart" \
        "${HOME}/sandboxed-containers-chart" \
        "${HOME}/sandboxed-policies-chart"; do
        [[ -d "$candidate/.git" ]] && lab_repos+=("$candidate")
    done
    if [[ ${#lab_repos[@]} -gt 0 ]]; then
        GIT_REPOS="${lab_repos[*]}"
        export GIT_REPOS
        info "Lab git repos: ${GIT_REPOS}"
    fi
fi

# routingViaHost only makes sense around the full bootstrap; the generic
# script's mode flags (sync/deploy/repoint) target an already-bootstrapped
# cluster and skip it.
if [[ $# -eq 0 ]]; then
    enable_routing_via_host
fi

exec "${SCRIPT_DIR}/airgap-post-install.sh" "$@"
