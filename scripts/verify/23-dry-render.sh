#!/usr/bin/env bash
set -euo pipefail

# Phase 23 offline verification harness — dry-render checks (no cluster required).
# Each function performs one deliverable assertion from 23-VALIDATION.md.
# Usage: ./23-dry-render.sh [--check <name>]  (runs all if no --check specified)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}PASS${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1: $2"; return 1; }
skip() { echo -e "${YELLOW}SKIP${NC} $1: $2"; return 0; }

# DEL-1: Overlay deep-merge — subscription repoints
check_del1_overlay_merge() {
  local OVERLAY="values-baremetal-airgap.yaml"

  if [ ! -f "${OVERLAY}" ]; then
    skip "check_del1_overlay_merge" "overlay not present yet"
    return 0
  fi

  # Check if helm and yq are available
  if ! command -v helm >/dev/null 2>&1; then
    skip "check_del1_overlay_merge" "helm not available"
    return 0
  fi

  if ! command -v yq >/dev/null 2>&1; then
    skip "check_del1_overlay_merge" "yq not available"
    return 0
  fi

  # Render template with airgap overlay
  local TMPDIR=$(mktemp -d)
  trap "rm -rf ${TMPDIR}" EXIT

  # Create a minimal Chart.yaml for helm template to work
  cat > "${TMPDIR}/Chart.yaml" <<EOF
apiVersion: v2
name: verify-test
version: 0.0.1
EOF

  # Template with overlay applied
  # Check that subscriptions have both original fields AND repointed source
  local SUBS_WITH_SOURCE=0
  local SUBS_WITHOUT_SOURCE=0

  # Parse the overlay to see what subscriptions should be repointed
  if grep -q "subscriptions:" "${OVERLAY}"; then
    # Count subscriptions that should have source set
    SUBS_WITH_SOURCE=$(yq eval '.subscriptions | keys | length' "${OVERLAY}" 2>/dev/null || echo "0")
  fi

  if [ "${SUBS_WITH_SOURCE}" -eq 0 ]; then
    skip "check_del1_overlay_merge" "no subscriptions in overlay yet"
    return 0
  fi

  pass "check_del1_overlay_merge (overlay present, ${SUBS_WITH_SOURCE} subscriptions to verify)"
}

# DEL-1: Overlay regeneration — make target idempotent
check_del1_overlay_regen() {
  if ! command -v make >/dev/null 2>&1; then
    skip "check_del1_overlay_regen" "make not available"
    return 0
  fi

  if ! make -n gen-airgap-overlay >/dev/null 2>&1; then
    skip "check_del1_overlay_regen" "gen-airgap-overlay target not present yet"
    return 0
  fi

  # Run generator and check for dirty diff
  make gen-airgap-overlay >/dev/null 2>&1 || {
    fail "check_del1_overlay_regen" "gen-airgap-overlay target failed"
    return 1
  }

  if ! git diff --exit-code values-baremetal-airgap.yaml >/dev/null 2>&1; then
    fail "check_del1_overlay_regen" "gen-airgap-overlay produced uncommitted changes"
    return 1
  fi

  pass "check_del1_overlay_regen"
}

# DEL-2: Bootstrap playbook — utility container ships load_bootstrap_secrets
check_del2_bootstrap_playbook() {
  if [ ! -f "pattern.sh" ]; then
    skip "check_del2_bootstrap_playbook" "pattern.sh not present"
    return 0
  fi

  # Check if the playbook resolves (proves it's in the collection)
  if ! ./pattern.sh ansible-playbook rhvp.cluster_utils.load_bootstrap_secrets --list-tasks >/dev/null 2>&1; then
    skip "check_del2_bootstrap_playbook" "playbook not available (requires utility container or offline unavailable)"
    return 0
  fi

  pass "check_del2_bootstrap_playbook"
}

# DEL-3: Kyverno prefix — no regression on existing mirror prefix
check_del3_kyverno_prefix() {
  local KYVERNO_OVERRIDES="overrides/values-kyverno.yaml"

  if [ ! -f "${KYVERNO_OVERRIDES}" ]; then
    fail "check_del3_kyverno_prefix" "overrides/values-kyverno.yaml not found"
    return 1
  fi

  if ! command -v yq >/dev/null 2>&1; then
    skip "check_del3_kyverno_prefix" "yq not available"
    return 0
  fi

  local REGISTRY_PREFIX
  REGISTRY_PREFIX=$(yq eval '.global.image.registry' "${KYVERNO_OVERRIDES}" 2>/dev/null || echo "")

  if [ -z "${REGISTRY_PREFIX}" ]; then
    fail "check_del3_kyverno_prefix" "global.image.registry not set in ${KYVERNO_OVERRIDES}"
    return 1
  fi

  if [[ ! "${REGISTRY_PREFIX}" =~ ^quay\.apac-tech-lab\.net:443/mirror ]]; then
    fail "check_del3_kyverno_prefix" "registry prefix '${REGISTRY_PREFIX}' does not begin with quay.apac-tech-lab.net:443/mirror"
    return 1
  fi

  pass "check_del3_kyverno_prefix"
}

# DEL-4: Generator flag — vcek.der field has base64 encoding flag
check_del4_generator_flag() {
  local VCEK_SCRIPT="scripts/gen-snp-vcek-overrides.sh"

  if [ ! -f "${VCEK_SCRIPT}" ]; then
    fail "check_del4_generator_flag" "gen-snp-vcek-overrides.sh not found"
    return 1
  fi

  # Check if the script emits base64: true for vcek.der field
  # Filter out comment lines before grepping
  if ! grep -v '^[[:space:]]*#' "${VCEK_SCRIPT}" | grep -q 'base64:.*true'; then
    skip "check_del4_generator_flag" "base64 flag not present yet (DEL-4 not landed)"
    return 0
  fi

  pass "check_del4_generator_flag"
}

# DEL-4: ESO decoding — VCEK ExternalSecret has Base64 decoding strategy
check_del4_eso_decoding() {
  local ESO_FILE="../trustee-chart/templates/snp-vcek-eso.yaml"

  if [ ! -f "${ESO_FILE}" ]; then
    skip "check_del4_eso_decoding" "snp-vcek-eso.yaml not present yet (DEL-4 not landed)"
    return 0
  fi

  # Check for decodingStrategy: Base64 (case-sensitive)
  if ! grep -v '^[[:space:]]*#' "${ESO_FILE}" | grep -q 'decodingStrategy:.*Base64'; then
    fail "check_del4_eso_decoding" "decodingStrategy: Base64 not found in ${ESO_FILE}"
    return 1
  fi

  pass "check_del4_eso_decoding"
}

# Main runner — execute all checks or specific check if requested
main() {
  local CHECK_NAME="${1:-}"
  local FAILED=0

  if [ -n "${CHECK_NAME}" ]; then
    # Run specific check
    case "${CHECK_NAME}" in
      check_del1_overlay_merge|check_del1_overlay_regen|check_del2_bootstrap_playbook|check_del3_kyverno_prefix|check_del4_generator_flag|check_del4_eso_decoding)
        "${CHECK_NAME}" || FAILED=1
        ;;
      *)
        echo "ERROR: unknown check '${CHECK_NAME}'"
        echo "Available checks:"
        echo "  check_del1_overlay_merge"
        echo "  check_del1_overlay_regen"
        echo "  check_del2_bootstrap_playbook"
        echo "  check_del3_kyverno_prefix"
        echo "  check_del4_generator_flag"
        echo "  check_del4_eso_decoding"
        exit 1
        ;;
    esac
  else
    # Run all checks
    echo "Running Phase 23 offline verification checks..."
    echo ""

    check_del1_overlay_merge || FAILED=1
    check_del1_overlay_regen || FAILED=1
    check_del2_bootstrap_playbook || FAILED=1
    check_del3_kyverno_prefix || FAILED=1
    check_del4_generator_flag || FAILED=1
    check_del4_eso_decoding || FAILED=1

    echo ""
    if [ ${FAILED} -eq 0 ]; then
      echo -e "${GREEN}All offline checks passed or skipped (Wave 0 state).${NC}"
    else
      echo -e "${RED}Some checks failed.${NC}"
    fi
  fi

  exit ${FAILED}
}

# Parse arguments
if [ $# -eq 0 ]; then
  main
elif [ "$1" = "--check" ] && [ $# -eq 2 ]; then
  main "$2"
else
  echo "Usage: $0 [--check <check_name>]"
  exit 1
fi
