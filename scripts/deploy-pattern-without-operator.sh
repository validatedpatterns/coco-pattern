#!/usr/bin/env bash
# Deploy the CoCo pattern WITHOUT relying on the patterns-operator.
#
# Used when the patterns-operator can't install due to Quay OCI manifest
# limitations (hybrid OCI index with Docker v2s2 children rejected).
#
# This script replicates what the patterns-operator does:
#   1. Installs OpenShift GitOps operator
#   2. Creates the VP ArgoCD instance (vp-gitops namespace)
#   3. Creates the ArgoCD Application for the pattern
#   4. Configures ArgoCD with Quay CA cert and Helm OCI auth
#
# Usage: ./scripts/deploy-pattern-without-operator.sh
# Prerequisites: KUBECONFIG set, MIRROR_REGISTRY set

set -euo pipefail

MIRROR_REGISTRY="${MIRROR_REGISTRY:-quay.apac-tech-lab.net:443/mirror}"
GITOPS_SOURCE="${GITOPS_SOURCE:-cs-redhat-operator-index-v4-21}"
PATTERN_REPO="${PATTERN_REPO:-http://172.25.36.135:8080/coco-pattern.git}"
PATTERN_BRANCH="${PATTERN_BRANCH:-dev/airgap-testing}"
HELM_REPO="${HELM_REPO:-${MIRROR_REGISTRY}/validatedpatterns}"

echo "==========================================="
echo "  Deploy CoCo Pattern (operator bypass)"
echo "==========================================="
echo "  Mirror: ${MIRROR_REGISTRY}"
echo "  Repo:   ${PATTERN_REPO}"
echo "  Branch: ${PATTERN_BRANCH}"
echo "  Helm:   ${HELM_REPO}"
echo ""

# Step 1: Install GitOps operator
echo "=== Step 1: Install GitOps operator ==="
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-gitops-operator
  source: ${GITOPS_SOURCE}
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

echo "Waiting for GitOps CSV..."
for i in $(seq 1 30); do
    CSV=$(oc get csv -A 2>/dev/null | grep gitops | grep Succeeded | head -1)
    [ -n "$CSV" ] && echo "Installed!" && break
    echo "  ($i/30)..."
    sleep 10
done

# Step 2: Wait for default ArgoCD
echo ""
echo "=== Step 2: Wait for ArgoCD ==="
for i in $(seq 1 12); do
    ARGOCD=$(oc get argocd -n openshift-gitops --no-headers 2>/dev/null)
    [ -n "$ARGOCD" ] && echo "ArgoCD ready" && break
    echo "  ($i/12)..."
    sleep 10
done

# Step 3: Grant cluster-admin to ArgoCD
echo ""
echo "=== Step 3: Grant cluster-admin ==="
oc adm policy add-cluster-role-to-user cluster-admin \
    system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller 2>&1

# Step 4: Add Quay CA cert
echo ""
echo "=== Step 4: Configure ArgoCD TLS ==="
QUAY_HOST=$(echo "${MIRROR_REGISTRY}" | cut -d/ -f1 | cut -d: -f1)
if [ -f ~/quay-ca-chain.pem ]; then
    cat <<EOCM | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-tls-certs-cm
  namespace: openshift-gitops
  labels:
    app.kubernetes.io/part-of: argocd
data:
  ${QUAY_HOST}: |
$(cat ~/quay-ca-chain.pem | sed 's/^/    /')
EOCM
    echo "TLS cert added for ${QUAY_HOST}"
fi

# Step 5: Helm OCI auth — SKIPPED
# Quay repos are public (ANONYMOUS_ACCESS: true). Mounting the pull-secret
# as HELM_REGISTRY_CONFIG causes 401 errors because Quay rejects the Basic
# auth format from the pull-secret when Bearer is expected. Unauthenticated
# Helm OCI pulls work correctly.
echo ""
echo "=== Step 5: Helm OCI auth — skipped (public repos) ==="

# Step 6: Create the parent ArgoCD Application
echo ""
echo "=== Step 6: Create pattern Application ==="
cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: coco-pattern-baremetal
  namespace: openshift-gitops
spec:
  destination:
    name: in-cluster
    namespace: openshift-operators
  project: default
  sources:
  - ref: patternref
    repoURL: ${PATTERN_REPO}
    targetRevision: ${PATTERN_BRANCH}
  - chart: clustergroup
    repoURL: ${HELM_REPO}
    targetRevision: "0.9.*"
    helm:
      ignoreMissingValueFiles: true
      parameters:
      - name: global.pattern
        value: coco-pattern
      - name: global.namespace
        value: openshift-operators
      - name: global.repoURL
        value: ${PATTERN_REPO}
      - name: global.targetRevision
        value: ${PATTERN_BRANCH}
      - name: global.hubClusterDomain
        value: $(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
      - name: global.localClusterDomain
        value: $(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
      - name: clusterGroup.name
        value: baremetal
      - name: clusterGroup.isHubCluster
        value: "true"
      valueFiles:
      - \$patternref/values-global.yaml
      - \$patternref/values-baremetal.yaml
  syncPolicy:
    automated:
      selfHeal: true
EOF

echo ""
echo "=== Waiting for app sync ==="
for i in $(seq 1 12); do
    APP=$(oc get application coco-pattern-baremetal -n openshift-gitops --no-headers 2>/dev/null)
    echo "  ($i/12) ${APP:-creating...}"
    sleep 10
done

echo ""
echo "=== Done ==="
oc get applications.argoproj.io -A --no-headers 2>/dev/null | head -10
