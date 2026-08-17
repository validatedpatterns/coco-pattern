#!/usr/bin/env bash
set -euo pipefail

# Phase 23 live verification harness — APAC-lab cluster checks.
# Each function performs one deliverable assertion from 23-VALIDATION.md that requires a cluster.
# Usage: ./23-live.sh [--dry] [--check <name>]
#   --dry: print intended commands without executing (offline-safe)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DRY_RUN=false

pass() { echo -e "${GREEN}PASS${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1: $2"; return 1; }
skip() { echo -e "${YELLOW}SKIP${NC} $1: $2"; return 0; }
info() { echo -e "${BLUE}INFO${NC} $1"; }

# Parse arguments
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry)
        DRY_RUN=true
        shift
        ;;
      --check)
        CHECK_NAME="$2"
        shift 2
        ;;
      *)
        echo "Usage: $0 [--dry] [--check <check_name>]"
        exit 1
        ;;
    esac
  done
}

# Check KUBECONFIG and cluster access
check_cluster_access() {
  if [ -z "${KUBECONFIG:-}" ]; then
    echo "ERROR: KUBECONFIG not set — live checks require a cluster."
    echo ""
    echo "To run these checks on the APAC lab cluster:"
    echo "  ssh chbutler@user-jump.int.apac-tech-lab.net"
    echo "  export KUBECONFIG=~/node-02-airgap-output/42124_rebuild_20260723_1038/auth/kubeconfig"
    echo "  cd ~/coco-pattern"
    echo "  bash scripts/verify/23-live.sh"
    echo ""
    echo "To verify syntax offline, run: $0 --dry"
    exit 1
  fi

  if ! oc whoami >/dev/null 2>&1; then
    echo "ERROR: cannot authenticate to cluster (oc whoami failed)."
    echo "Verify KUBECONFIG is valid and the cluster is reachable."
    exit 1
  fi
}

# DEL-1: Naming contract — every subscription source matches a CatalogSource
check_del1_naming_contract() {
  if ${DRY_RUN}; then
    info "check_del1_naming_contract [DRY]"
    echo "  Command: oc get sub -A -o jsonpath='{.items[*].spec.source}' | tr ' ' '\\n' | sort -u"
    echo "  For each source: oc get catalogsource -n openshift-marketplace <name>"
    return 0
  fi

  local SOURCES
  SOURCES=$(oc get sub -A -o jsonpath='{.items[*].spec.source}' 2>/dev/null | tr ' ' '\n' | sort -u)

  if [ -z "${SOURCES}" ]; then
    skip "check_del1_naming_contract" "no subscriptions found"
    return 0
  fi

  local MISSING=()
  for SOURCE in ${SOURCES}; do
    if ! oc get catalogsource -n openshift-marketplace "${SOURCE}" >/dev/null 2>&1; then
      MISSING+=("${SOURCE}")
    fi
  done

  if [ ${#MISSING[@]} -gt 0 ]; then
    echo -e "${RED}FAIL${NC} check_del1_naming_contract: missing CatalogSources:"
    for NAME in "${MISSING[@]}"; do
      echo "  - ${NAME}"
    done
    return 1
  fi

  pass "check_del1_naming_contract (all subscription sources have matching CatalogSources)"
}

# DEL-2: Bootstrap secret — mirror-registry-helm-oci exists with correct fields
check_del2_bootstrap_secret() {
  if ${DRY_RUN}; then
    info "check_del2_bootstrap_secret [DRY]"
    echo "  Command: oc -n vp-gitops get secret mirror-registry-helm-oci"
    echo "  Decode .data.type → 'helm'"
    echo "  Decode .data.enableOCI → 'true'"
    return 0
  fi

  if ! oc -n vp-gitops get secret mirror-registry-helm-oci >/dev/null 2>&1; then
    fail "check_del2_bootstrap_secret" "secret mirror-registry-helm-oci not found in namespace vp-gitops"
    return 1
  fi

  local TYPE_FIELD
  TYPE_FIELD=$(oc -n vp-gitops get secret mirror-registry-helm-oci -o jsonpath='{.data.type}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

  if [ "${TYPE_FIELD}" != "helm" ]; then
    fail "check_del2_bootstrap_secret" ".data.type is '${TYPE_FIELD}', expected 'helm'"
    return 1
  fi

  local ENABLE_OCI
  ENABLE_OCI=$(oc -n vp-gitops get secret mirror-registry-helm-oci -o jsonpath='{.data.enableOCI}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

  if [ "${ENABLE_OCI}" != "true" ]; then
    fail "check_del2_bootstrap_secret" ".data.enableOCI is '${ENABLE_OCI}', expected 'true'"
    return 1
  fi

  pass "check_del2_bootstrap_secret"
}

# DEL-2: Chart pull — ArgoCD pulls from authenticated mirror-registry OCI
check_del2_chart_pull() {
  local MIRROR="${MIRROR_REGISTRY:-MIRROR_REGISTRY_HOST:8443}"
  if ${DRY_RUN}; then
    info "check_del2_chart_pull [DRY]"
    echo "  Command: argocd repo get ${MIRROR}/validatedpatterns"
    echo "  Or: create throwaway Application targeting mirrored chart, check Synced/Healthy"
    return 0
  fi

  # Prefer argocd CLI if available
  if command -v argocd >/dev/null 2>&1; then
    local REPO_URL="${MIRROR}/validatedpatterns"
    if argocd repo get "${REPO_URL}" --core 2>&1 | grep -q "TYPE.*helm"; then
      pass "check_del2_chart_pull (argocd repo confirms OCI-helm connection)"
      return 0
    fi
  fi

  # Fallback: check for existing ArgoCD Applications pulling from mirror
  local MIRROR_APPS
  MIRROR_APPS=$(oc get applications.argoproj.io -A -o json 2>/dev/null | \
    jq -r --arg reg "${MIRROR}" '.items[] | select(.spec.source.repoURL | contains($reg)) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")

  if [ -z "${MIRROR_APPS}" ]; then
    skip "check_del2_chart_pull" "no Applications targeting mirrored charts found (needs in-phase validation)"
    return 0
  fi

  # Check if at least one is Synced and Healthy
  local HEALTHY_APPS=0
  for APP in ${MIRROR_APPS}; do
    local NS="${APP%%/*}"
    local NAME="${APP##*/}"
    local HEALTH
    HEALTH=$(oc get application.argoproj.io "${NAME}" -n "${NS}" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
    local SYNC
    SYNC=$(oc get application.argoproj.io "${NAME}" -n "${NS}" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")

    if [ "${HEALTH}" = "Healthy" ] && [ "${SYNC}" = "Synced" ]; then
      HEALTHY_APPS=$((HEALTHY_APPS + 1))
    fi
  done

  if [ ${HEALTHY_APPS} -gt 0 ]; then
    pass "check_del2_chart_pull (${HEALTHY_APPS} Applications pulling from mirrored Quay are Healthy+Synced)"
    return 0
  fi

  fail "check_del2_chart_pull" "found Applications targeting mirror but none are Healthy+Synced"
  return 1
}

# DEL-4: DER round-trip — byte-identity through secrets pipeline
check_del4_der_roundtrip() {
  local SECRET_NAME="${1:-snp-vcek-test}"

  if ${DRY_RUN}; then
    info "check_del4_der_roundtrip [DRY]"
    echo "  1. scripts/verify/fixtures/gen-der-fixture.sh /tmp/fake.der"
    echo "  2. Load /tmp/fake.der through secrets pipeline with base64: true"
    echo "  3. oc get secret ${SECRET_NAME} -o jsonpath='{.data.vcek\\.der}' | base64 -d > /tmp/out.der"
    echo "  4. openssl x509 -inform DER -in /tmp/out.der -noout"
    echo "  5. cmp /tmp/fake.der /tmp/out.der"
    return 0
  fi

  # Generate fixture
  if ! bash scripts/verify/fixtures/gen-der-fixture.sh /tmp/fake.der >/dev/null 2>&1; then
    fail "check_del4_der_roundtrip" "fixture generation failed"
    return 1
  fi

  # For this check to work, the secret must already be loaded
  # This is a parameterized check that DEL-4's plan will supply the secret name for
  if ! oc get secret "${SECRET_NAME}" -n trustee-system >/dev/null 2>&1; then
    skip "check_del4_der_roundtrip" "secret ${SECRET_NAME} not found (DEL-4 not validated yet)"
    return 0
  fi

  # Extract vcek.der from secret
  if ! oc get secret "${SECRET_NAME}" -n trustee-system -o jsonpath='{.data.vcek\.der}' | base64 -d > /tmp/out.der 2>/dev/null; then
    fail "check_del4_der_roundtrip" "failed to extract vcek.der from secret"
    return 1
  fi

  # Verify openssl can parse it
  if ! openssl x509 -inform DER -in /tmp/out.der -noout 2>/dev/null; then
    fail "check_del4_der_roundtrip" "output DER is not a valid certificate"
    return 1
  fi

  # Byte-identity check
  if ! cmp /tmp/fake.der /tmp/out.der >/dev/null 2>&1; then
    fail "check_del4_der_roundtrip" "byte-identity check failed (input != output)"
    return 1
  fi

  pass "check_del4_der_roundtrip"
}

# Main runner
main() {
  local CHECK_NAME="${CHECK_NAME:-}"
  local FAILED=0

  # Banner
  if ${DRY_RUN}; then
    echo "Phase 23 live verification checks (DRY RUN — no cluster access)"
    echo ""
  else
    echo "Phase 23 live verification checks"
    echo ""
    check_cluster_access
    echo ""
  fi

  if [ -n "${CHECK_NAME}" ]; then
    # Run specific check
    case "${CHECK_NAME}" in
      check_del1_naming_contract|check_del2_bootstrap_secret|check_del2_chart_pull|check_del4_der_roundtrip)
        "${CHECK_NAME}" || FAILED=1
        ;;
      *)
        echo "ERROR: unknown check '${CHECK_NAME}'"
        echo "Available checks:"
        echo "  check_del1_naming_contract"
        echo "  check_del2_bootstrap_secret"
        echo "  check_del2_chart_pull"
        echo "  check_del4_der_roundtrip"
        exit 1
        ;;
    esac
  else
    # Run all checks
    check_del1_naming_contract || FAILED=1
    check_del2_bootstrap_secret || FAILED=1
    check_del2_chart_pull || FAILED=1
    check_del4_der_roundtrip || FAILED=1

    echo ""
    if [ ${FAILED} -eq 0 ]; then
      if ${DRY_RUN}; then
        echo -e "${GREEN}All live checks are syntactically valid (dry run).${NC}"
      else
        echo -e "${GREEN}All live checks passed or skipped.${NC}"
      fi
    else
      echo -e "${RED}Some checks failed.${NC}"
    fi
  fi

  exit ${FAILED}
}

# Entry point
CHECK_NAME=""
parse_args "$@"
main
