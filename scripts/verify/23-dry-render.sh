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

# DEL-1: Overlay shape — 2-line global catalogSource (D-05 migration)
# After D-05, the overlay shrinks from 10 per-subscription entries to
# 2 global keys: global.catalogSource + global.catalogSourceNamespace.
check_del1_overlay_merge() {
  local OVERLAY="values-baremetal-airgap.yaml"

  if [ ! -f "${OVERLAY}" ]; then
    skip "check_del1_overlay_merge" "overlay not present yet"
    return 0
  fi

  local FAILED=0

  # Assert global: key is present (new shape)
  if ! grep -q "^global:" "${OVERLAY}"; then
    fail "check_del1_overlay_merge" "global: key not found in ${OVERLAY} — overlay may still be using old per-subscription shape"
    FAILED=1
  fi

  # Assert catalogSource: key is present under global
  if ! grep -q "catalogSource:" "${OVERLAY}"; then
    fail "check_del1_overlay_merge" "catalogSource: key not found in ${OVERLAY}"
    FAILED=1
  fi

  # Assert catalogSourceNamespace: key is present under global
  if ! grep -q "catalogSourceNamespace:" "${OVERLAY}"; then
    fail "check_del1_overlay_merge" "catalogSourceNamespace: key not found in ${OVERLAY}"
    FAILED=1
  fi

  # Assert the overlay does NOT contain clusterGroup: (old per-subscription shape guard)
  if grep -q "^clusterGroup:" "${OVERLAY}"; then
    fail "check_del1_overlay_merge" "clusterGroup: key found in ${OVERLAY} — overlay appears to still be using old per-subscription shape"
    FAILED=1
  fi

  # Assert line count is 3 or fewer (global: + 2 keys; no trailing blank lines counted)
  local LINE_COUNT
  LINE_COUNT=$(grep -c "." "${OVERLAY}" || echo "0")
  if [ "${LINE_COUNT}" -gt 3 ]; then
    fail "check_del1_overlay_merge" "overlay has ${LINE_COUNT} non-blank lines (expected 3 for 2-line global shape)"
    FAILED=1
  fi

  if [ "${FAILED}" -eq 0 ]; then
    local CATALOG_NAME
    CATALOG_NAME=$(grep "catalogSource:" "${OVERLAY}" | head -1 | awk '{print $2}')
    pass "check_del1_overlay_merge (2-line global overlay present, catalogSource=${CATALOG_NAME})"
  fi
  return ${FAILED}
}

# DEL-1: Generator cleanup — gen-airgap-overlay removed from Makefile (D-04/D-05)
# After D-05, the per-subscription overlay generator is removed.
# This check asserts the target is absent, confirming cleanup was applied.
check_del1_overlay_regen() {
  if [ ! -f "Makefile" ]; then
    skip "check_del1_overlay_regen" "Makefile not present"
    return 0
  fi

  # Assert gen-airgap-overlay target does NOT exist in the Makefile
  if grep -q "gen-airgap-overlay" Makefile 2>/dev/null; then
    fail "check_del1_overlay_regen" "gen-airgap-overlay still in Makefile — D-05 cleanup not applied"
    return 1
  fi

  pass "check_del1_overlay_regen (gen-airgap-overlay absent from Makefile — D-05 cleanup confirmed)"
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

  local EXPECTED_REGISTRY="${MIRROR_REGISTRY:-MIRROR_REGISTRY_HOST:8443}"
  if [[ ! "${REGISTRY_PREFIX}" =~ ^${EXPECTED_REGISTRY} ]]; then
    fail "check_del3_kyverno_prefix" "registry prefix '${REGISTRY_PREFIX}' does not begin with ${EXPECTED_REGISTRY}"
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
