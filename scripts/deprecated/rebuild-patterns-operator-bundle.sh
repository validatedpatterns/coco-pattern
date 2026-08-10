#!/usr/bin/env bash
# Rebuild the patterns-operator OLM bundle with amd64-only image digests.
#
# Quay with OCI-only mode rejects hybrid OCI manifest lists (OCI index +
# Docker v2s2 children). The patterns-operator images are multi-arch but
# the mirror only stores single-arch (amd64) variants with different digests.
#
# This script:
#   1. Extracts the original bundle from the community catalog
#   2. Patches the CSV with amd64 single-arch digests
#   3. Rebuilds and pushes the bundle image
#   4. Rebuilds and pushes the community catalog with the patched bundle
#   5. Updates the CatalogSource to use the patched catalog
#   6. Cleans up OLM caches and re-creates the subscription
#
# Usage: ./scripts/rebuild-patterns-operator-bundle.sh
# Prerequisites: podman, oc CLI, KUBECONFIG set, access to Quay mirror

set -euo pipefail

MIRROR="quay.apac-tech-lab.net:443/mirror"
NS="openshift-operators"
MARKETPLACE_NS="openshift-marketplace"

# Multi-arch → amd64 digest mappings
OPERATOR_MULTI="sha256:eeb82d8c13fdb0c18603f11ee5cb16b8411806c1df3ebca75911fb2b87906306"
OPERATOR_AMD64="sha256:e6c2bbb5d30ac9a8aff18b4bf7267d29469a68dad74adb201300795923aaef12"
CONSOLE_MULTI="sha256:ba657cf52ee099709d069db06359b588b7344f2472996ba8973f3d6a62cbb3e8"
CONSOLE_AMD64="sha256:4bc1351becc5cb13b2ce4af40fcb2fc1e2e1526698d2942ecbeccdbe85b92521"

WORK_DIR=$(mktemp -d /tmp/bundle-rebuild-XXXXXX)
echo "Work dir: ${WORK_DIR}"

# Step 1: Extract bundle image contents
echo ""
echo "=== Step 1: Extract bundle image ==="
BUNDLE_IMG="${MIRROR}/community-operator-pipeline-prod/patterns-operator:0.0.78"
podman create --name bundle-extract "${BUNDLE_IMG}" 2>/dev/null || \
  { podman rm bundle-extract 2>/dev/null; podman create --name bundle-extract "${BUNDLE_IMG}"; }
podman cp bundle-extract:/manifests "${WORK_DIR}/manifests"
podman cp bundle-extract:/metadata "${WORK_DIR}/metadata"
podman rm bundle-extract
echo "Extracted manifests and metadata"

# Step 2: Patch CSV with amd64 digests
echo ""
echo "=== Step 2: Patch CSV ==="
CSV_FILE=$(ls "${WORK_DIR}/manifests/"*clusterserviceversion.yaml 2>/dev/null | head -1)
echo "CSV: ${CSV_FILE}"

sed -i "s|${OPERATOR_MULTI}|${OPERATOR_AMD64}|g" "${CSV_FILE}"
sed -i "s|${CONSOLE_MULTI}|${CONSOLE_AMD64}|g" "${CSV_FILE}"

# Verify
grep -c "${OPERATOR_AMD64}" "${CSV_FILE}" && echo "Operator digest patched"
grep -c "${CONSOLE_AMD64}" "${CSV_FILE}" && echo "Console digest patched"
! grep -q "${OPERATOR_MULTI}" "${CSV_FILE}" && echo "No multi-arch operator digest remaining"
! grep -q "${CONSOLE_MULTI}" "${CSV_FILE}" && echo "No multi-arch console digest remaining"

# Step 3: Rebuild bundle image
echo ""
echo "=== Step 3: Rebuild bundle image ==="
cat > "${WORK_DIR}/Dockerfile.bundle" <<EOF
FROM scratch
COPY manifests /manifests
COPY metadata /metadata
LABEL operators.operatorframework.io.bundle.mediatype.v1=registry+v1
LABEL operators.operatorframework.io.bundle.manifests.v1=manifests/
LABEL operators.operatorframework.io.bundle.metadata.v1=metadata/
LABEL operators.operatorframework.io.bundle.package.v1=patterns-operator
LABEL operators.operatorframework.io.bundle.channels.v1=fast
LABEL operators.operatorframework.io.bundle.channel.default.v1=fast
EOF

PATCHED_BUNDLE="${MIRROR}/community-operator-pipeline-prod/patterns-operator:0.0.78-amd64"
podman build -t "${PATCHED_BUNDLE}" -f "${WORK_DIR}/Dockerfile.bundle" "${WORK_DIR}" 2>&1 | tail -3
podman push "${PATCHED_BUNDLE}" --tls-verify=false 2>&1 | tail -1
echo "Bundle pushed: ${PATCHED_BUNDLE}"

# Get the digest of the pushed bundle
PATCHED_BUNDLE_DIGEST=$(podman inspect "${PATCHED_BUNDLE}" --format='{{.Digest}}')
echo "Bundle digest: ${PATCHED_BUNDLE_DIGEST}"

# Step 4: Rebuild catalog with patched bundle reference
echo ""
echo "=== Step 4: Rebuild catalog ==="
CATALOG_POD=$(oc get pod -n "${MARKETPLACE_NS}" -l olm.catalogSource=cs-community-operator-index-v4-21 -o jsonpath='{.items[0].metadata.name}')
echo "Catalog pod: ${CATALOG_POD}"

mkdir -p "${WORK_DIR}/catalog-configs"
oc cp -n "${MARKETPLACE_NS}" "${CATALOG_POD}:/configs" "${WORK_DIR}/catalog-configs/" 2>&1 | tail -1

# Patch the catalog to use the patched bundle AND patched relatedImages
CATALOG_JSON="${WORK_DIR}/catalog-configs/configs/patterns-operator/catalog.json"
python3 -c "
content = open('${CATALOG_JSON}').read()
# Replace the bundle image reference
content = content.replace(
    'quay.io/community-operator-pipeline-prod/patterns-operator:0.0.78',
    '${PATCHED_BUNDLE}'
)
# Replace multi-arch digests with amd64
content = content.replace('${OPERATOR_MULTI}', '${OPERATOR_AMD64}')
content = content.replace('${CONSOLE_MULTI}', '${CONSOLE_AMD64}')
open('${CATALOG_JSON}', 'w').write(content)
print('Catalog patched')
"

PATCHED_CATALOG="${MIRROR}/redhat/community-operator-index:v4.21-amd64-bundle"
cat > "${WORK_DIR}/Dockerfile.catalog" <<EOF
FROM ${MIRROR}/redhat/community-operator-index:v4.21
COPY catalog-configs/configs /configs
EOF

podman build -t "${PATCHED_CATALOG}" -f "${WORK_DIR}/Dockerfile.catalog" "${WORK_DIR}" 2>&1 | tail -3
podman push "${PATCHED_CATALOG}" --tls-verify=false 2>&1 | tail -1
echo "Catalog pushed: ${PATCHED_CATALOG}"

# Step 5: Update CatalogSource
echo ""
echo "=== Step 5: Update CatalogSource ==="
oc patch catalogsource cs-community-operator-index-v4-21 -n "${MARKETPLACE_NS}" --type merge \
  -p "{\"spec\":{\"image\":\"${PATCHED_CATALOG}\"}}"

# Step 6: Clean up and reinstall
echo ""
echo "=== Step 6: Clean up and reinstall ==="
oc delete csv patterns-operator.v0.0.78 -n "${NS}" 2>/dev/null || true
oc delete sub patterns-operator -n "${NS}" 2>/dev/null || true
oc delete installplan -n "${NS}" --all 2>/dev/null || true
oc delete configmap -n "${MARKETPLACE_NS}" -l olm.operatorframework.io/bundle 2>/dev/null || true
# Delete by name pattern
oc get configmap -n "${MARKETPLACE_NS}" --no-headers 2>/dev/null | grep -E "^[0-9a-f]" | awk '{print $1}' | xargs -r oc delete configmap -n "${MARKETPLACE_NS}" 2>/dev/null || true
oc delete pod -n "${MARKETPLACE_NS}" -l olm.catalogSource=cs-community-operator-index-v4-21 --force --grace-period=0 2>/dev/null || true
oc delete pod -n openshift-operator-lifecycle-manager -l app=catalog-operator --force --grace-period=0 2>/dev/null || true
sleep 15

cat <<EOSUB | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: patterns-operator
  namespace: ${NS}
spec:
  channel: fast
  name: patterns-operator
  source: cs-community-operator-index-v4-21
  sourceNamespace: ${MARKETPLACE_NS}
EOSUB

echo ""
echo "=== Waiting for install ==="
for i in $(seq 1 36); do
    PODS=$(oc get pods -n "${NS}" 2>/dev/null | grep "pattern.*controller.*Running")
    if [ -n "$PODS" ]; then
        echo "RUNNING: ${PODS}"
        break
    fi
    CSV=$(oc get csv patterns-operator.v0.0.78 -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "  ($i/36) CSV: ${CSV:-pending}"
    sleep 10
done

# Cleanup
rm -rf "${WORK_DIR}"
echo ""
echo "=== Done ==="
oc get pods -n "${NS}" 2>/dev/null | grep pattern
oc get csv -n "${NS}" 2>/dev/null | grep pattern
