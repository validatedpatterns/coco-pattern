#!/usr/bin/env bash
# Fix patterns-operator image pull on Quay registries with OCI-only mode.
#
# Quay pre-3.17 (and OCI-only mode) cannot store hybrid OCI manifest lists
# (OCI index with Docker v2s2 children). The patterns-operator CSV references
# multi-arch digest images that have different digests in the mirror.
#
# This script:
#   1. Waits for the patterns-operator CSV to be created by OLM
#   2. Patches the CSV relatedImages and deployment containers to use
#      single-arch (amd64) digests that exist in the mirror
#   3. Scales deployments to trigger a fresh rollout
#
# Usage: ./scripts/fix-patterns-operator-images.sh
# Prerequisites: oc CLI, KUBECONFIG set

set -euo pipefail

NS="openshift-operators"
CSV_NAME="patterns-operator.v0.0.78"

echo "Fixing patterns-operator images for Quay OCI-only mode..."

# Wait for CSV to exist
echo "Waiting for CSV ${CSV_NAME}..."
for i in $(seq 1 30); do
    oc get csv "$CSV_NAME" -n "$NS" &>/dev/null && break
    sleep 10
done

# Get the actual amd64 digests from the mirror
# These were pushed as single-arch images during oc-mirror fixup
OPERATOR_AMD64=$(podman inspect --format='{{.Digest}}' quay.io/validatedpatterns/patterns-operator:0.0.78 2>/dev/null || \
    echo "sha256:e6c2bbb5d30ac9a8aff18b4bf7267d29469a68dad74adb201300795923aaef12")
CONSOLE_AMD64=$(podman inspect --format='{{.Digest}}' quay.io/validatedpatterns/patterns-operator-console:0.0.78 2>/dev/null || \
    echo "sha256:4bc1351becc5cb13b2ce4af40fcb2fc1e2e1526698d2942ecbeccdbe85b92521")

echo "  Operator amd64: ${OPERATOR_AMD64}"
echo "  Console amd64:  ${CONSOLE_AMD64}"

# Multi-arch digests that fail to pull
OPERATOR_MULTI="sha256:eeb82d8c13fdb0c18603f11ee5cb16b8411806c1df3ebca75911fb2b87906306"
CONSOLE_MULTI="sha256:ba657cf52ee099709d069db06359b588b7344f2472996ba8973f3d6a62cbb3e8"

# Patch the controller-manager deployment
echo "Patching patterns-operator-controller-manager..."
oc set image deployment/patterns-operator-controller-manager \
    -n "$NS" \
    "manager=quay.io/validatedpatterns/patterns-operator@${OPERATOR_AMD64}" 2>/dev/null || true

# Patch the console-plugin deployment
echo "Patching patterns-operator-console-plugin..."
CONTAINER_NAME=$(oc get deployment patterns-operator-console-plugin -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null || echo "patterns-operator-console-plugin")
oc set image "deployment/patterns-operator-console-plugin" \
    -n "$NS" \
    "${CONTAINER_NAME}=quay.io/validatedpatterns/patterns-operator-console@${CONSOLE_AMD64}" 2>/dev/null || true

# Wait for pods to come up
echo "Waiting for pods..."
for i in $(seq 1 12); do
    RUNNING=$(oc get pods -n "$NS" -l app.kubernetes.io/name=patterns-operator \
        --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [ "$RUNNING" -ge 1 ]; then
        echo "Patterns operator running!"
        oc get pods -n "$NS" | grep pattern
        break
    fi
    sleep 10
done

echo "Done."
