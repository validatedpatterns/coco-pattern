#!/usr/bin/env bash
# Stage 2: Install disconnected OpenShift cluster with CoCo pattern
# This script runs ON the bastion host
set -e 

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

if [ "$#" -ne 1 ]; then
    log_error "Exactly one argument is required."
    echo "Usage: $0 {azure-region-code}"
    echo "Example: $0 eastus"
    exit 1
fi

AZUREREGION=$1

log_info "=========================================="
log_info "Disconnected CoCo Pattern Installation"
log_info "Region: ${AZUREREGION}"
log_info "=========================================="

# Ensure running from pattern root
cd ~/coco-pattern

log_step "Validating environment"

# Source environment variables
if [ -f ~/.envrc ]; then
    source ~/.envrc
else
    log_error "Environment file ~/.envrc not found"
    exit 1
fi

# Validate RHDP environment variables
required_vars=("GUID" "CLIENT_ID" "PASSWORD" "TENANT" "SUBSCRIPTION" "RESOURCEGROUP")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log_error "RHDP environment variable '${var}' is not set"
        exit 1
    fi
done

# Validate ACR variables
if [ -z "${ACR_LOGIN_SERVER}" ]; then
    log_error "ACR_LOGIN_SERVER environment variable does not exist"
    exit 1
fi

# Get Terraform outputs for network configuration
log_step "Retrieving network configuration from Terraform"

# These were created by the provision script and should be available
# We'll try to extract from terraform state or use environment defaults
export VNET_NAME="${VNET_NAME:-vnet-coco-disconnected-${GUID}}"
export MASTER_SUBNET_NAME="${MASTER_SUBNET_NAME:-subnet-master}"
export WORKER_SUBNET_NAME="${WORKER_SUBNET_NAME:-subnet-worker}"

log_info "Network configuration:"
log_info "  VNet: ${VNET_NAME}"
log_info "  Master Subnet: ${MASTER_SUBNET_NAME}"
log_info "  Worker Subnet: ${WORKER_SUBNET_NAME}"

# Verify prerequisites
log_step "Verifying prerequisites"

if [ ! -f "${HOME}/pull-secret.json" ]; then
   log_error "OpenShift pull secret is required at ~/pull-secret.json"
   exit 1
fi

if [ ! -f "${HOME}/.ssh/id_rsa" ]; then
   log_error "An rsa ssh key is required at ~/.ssh/id_rsa"
   echo "e.g. ssh-keygen -t rsa -b 4096"
   exit 1
fi

# Verify mirror resources exist
CLUSTER_RESOURCES_DIR="${HOME}/coco-pattern/cluster-resources"
if [ ! -d "${CLUSTER_RESOURCES_DIR}" ]; then
    log_error "Cluster resources not found at ${CLUSTER_RESOURCES_DIR}"
    log_error "Please run mirror.sh first"
    exit 1
fi

log_info "Mirror resources found"

# Install Python dependencies if needed
log_step "Installing Python dependencies"
pip3 install --user jinja2 typer rich pyyaml --quiet

log_step "Generating disconnected cluster configuration"
python3 rhdp-isolated/bastion/rhdp-cluster-define-disconnected.py ${AZUREREGION}

log_info "Install config generated"
sleep 5

log_step "Starting OpenShift installation"
log_warn "This will take 45-60 minutes"

if ! openshift-install create cluster --dir=./openshift-install-disconnected; then
    log_error "OpenShift installation failed"
    log_error "Check logs in ./openshift-install-disconnected/.openshift_install.log"
    exit 1
fi

log_info "OpenShift cluster installed successfully"

# Set KUBECONFIG
export KUBECONFIG=$(pwd)/openshift-install-disconnected/auth/kubeconfig

log_step "Configuring cluster for disconnected operation"

# Apply IDMS and ITMS from mirroring
log_info "Applying ImageDigestMirrorSet configurations..."
for idms_file in ${CLUSTER_RESOURCES_DIR}/idms-*.yaml; do
    if [ -f "$idms_file" ]; then
        log_info "Applying $(basename $idms_file)"
        oc apply -f "$idms_file"
    fi
done

log_info "Applying ImageTagMirrorSet configurations..."
for itms_file in ${CLUSTER_RESOURCES_DIR}/itms-*.yaml; do
    if [ -f "$itms_file" ]; then
        log_info "Applying $(basename $itms_file)"
        oc apply -f "$itms_file"
    fi
done

log_info "Applying CatalogSource configurations..."
for cs_file in ${CLUSTER_RESOURCES_DIR}/cs-*.yaml; do
    if [ -f "$cs_file" ]; then
        log_info "Applying $(basename $cs_file)"
        oc apply -f "$cs_file"
    fi
done

log_info "Mirror configurations applied"
sleep 10

# Wait for catalog sources to be ready
log_info "Waiting for catalog sources to be ready (this may take 5-10 minutes)..."
sleep 30

# Check catalog source status
log_info "Checking catalog source status:"
oc get catalogsources -n openshift-marketplace

log_info "Waiting for cluster to stabilize..."
sleep 60

log_step "Setting up pattern secrets"
bash ./scripts/gen-secrets.sh

log_step "Installing CoCo pattern with disconnected configuration"

# Set environment variable to point to mirrored helm charts
export PATTERN_DISCONNECTED_HOME="${ACR_LOGIN_SERVER}/hybridcloudpatterns"

log_info "Using mirrored Helm repository: ${PATTERN_DISCONNECTED_HOME}"

# Validate values-disconnected.yaml exists
if [ ! -f "values-disconnected.yaml" ]; then
    log_error "values-disconnected.yaml not found"
    log_error "This file is required for disconnected installation"
    exit 1
fi

# IMPORTANT: Do NOT patch values-disconnected.yaml on the bastion!
# ArgoCD will read values files from Git, so any local patches are lost.
# Instead, we use --set to override values at install time.

# Build EXTRA_HELM_OPTS with both the values file AND runtime overrides
# The --set flag takes precedence over values files (per Makefile comment)
export EXTRA_HELM_OPTS="-f values-disconnected.yaml \
  --set main.multiSourceConfig.helmRepoUrl=${ACR_LOGIN_SERVER}/hybridcloudpatterns"

log_info "Helm options configured:"
log_info "  Base values: values-global.yaml (always loaded)"
log_info "  Cluster group: values-simple.yaml (from clusterGroupName)"
log_info "  Overlay: values-disconnected.yaml (catalog sources, operators)"
log_info "  Runtime override: --set main.multiSourceConfig.helmRepoUrl"
log_info ""
log_info "Disconnected configuration:"
log_info "  helmRepoUrl: ${ACR_LOGIN_SERVER}/hybridcloudpatterns (via --set)"
log_info "  Operator sources: cs-*-v4-20 (from values-disconnected.yaml)"
log_info ""
log_info "Why this approach:"
log_info "  1. ArgoCD reads values files from Git (not bastion)"
log_info "  2. --set overrides are baked into ArgoCD Application at install time"
log_info "  3. No need to modify files that ArgoCD syncs from Git"
log_info "  4. Avoids race conditions with helmRepoUrl availability"

# Install pattern
log_info "Running pattern installation..."
./pattern.sh make install

log_info "=========================================="
log_info "Installation Complete!"
log_info "=========================================="
log_info ""
log_info "Cluster Details:"
log_info "  Console: $(oc whoami --show-console)"
log_info "  API: $(oc whoami --show-server)"
log_info "  KUBECONFIG: ${KUBECONFIG}"
log_info ""
log_info "Credentials:"
log_info "  Username: kubeadmin"
log_info "  Password: $(cat ./openshift-install-disconnected/auth/kubeadmin-password)"
log_info ""
log_info "Disconnected Configuration:"
log_info "  Container Registry: ${ACR_LOGIN_SERVER}"
log_info "  Helm Repository: ${ACR_LOGIN_SERVER}/hybridcloudpatterns"
log_info "  Catalog Sources: cs-redhat-operator-index-v4-20, cs-community-operator-index-v4-20"
log_info ""
log_info "To access the cluster from this bastion:"
log_info "  export KUBECONFIG=$(pwd)/openshift-install-disconnected/auth/kubeconfig"
log_info "  oc get nodes"
log_info "  oc get clusterversion"
log_info ""
log_info "Monitor pattern deployment:"
log_info "  oc get applications -A"
log_info "  oc get pods -n openshift-gitops"
log_info "  oc get subscriptions -A"
log_info ""
log_info "Check CoCo/Sandboxed Containers:"
log_info "  oc get pods -n openshift-sandboxed-containers-operator"
log_info "  oc get kataconfig"
log_info ""

