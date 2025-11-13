#!/bin/bash
# SPDX-FileCopyrightText: 2024-present Red Hat Inc
# SPDX-License-Identifier: Apache-2.0
#
# OpenShift UPI (User-Provisioned Infrastructure) Installation Wrapper
# This script orchestrates the entire UPI deployment process with full control over VMs and IPs

set -euo pipefail

# Color output functions
log_info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARNING]\033[0m $*"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; }
log_step() { echo -e "\n\033[1;36m==>\033[0m \033[1m$*\033[0m\n"; }

# Validate required argument
if [ $# -ne 1 ]; then
    log_error "Usage: $0 <azure-region-code>"
    log_error "Example: $0 eastasia"
    exit 1
fi

AZURE_REGION="$1"

# Validate required environment variables
REQUIRED_VARS=("GUID" "RESOURCEGROUP" "ACR_LOGIN_SERVER" "SUBSCRIPTION" "CLIENT_ID" "PASSWORD" "TENANT")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        log_error "Required environment variable $var is not set"
        log_error "Please source your .envrc file"
        exit 1
    fi
done

# Validate required files
if [ ! -f ~/pull-secret.json ]; then
    log_error "Pull secret not found at ~/pull-secret.json"
    exit 1
fi

if [ ! -f ~/.ssh/id_rsa.pub ]; then
    log_error "SSH public key not found at ~/.ssh/id_rsa.pub"
    exit 1
fi

if [ ! -d ~/coco-pattern/cluster-resources ]; then
    log_error "Mirror resources not found at ~/coco-pattern/cluster-resources"
    log_error "Please run mirror.sh first"
    exit 1
fi

log_step "OpenShift UPI Installation Starting"
log_info "Cluster: coco-${GUID}"
log_info "Region: ${AZURE_REGION}"
log_info "Mode: UPI (User-Provisioned Infrastructure)"
log_info "Registry: ${ACR_LOGIN_SERVER}"

# Get bastion private IP for Git server
BASTION_PRIVATE_IP=$(hostname -I | awk '{print $1}')
GIT_HTTP_URL="http://${BASTION_PRIVATE_IP}:8080/coco-pattern"
GIT_BRANCH=$(cd ~/coco-pattern && git branch --show-current)

log_info "Git server: ${GIT_HTTP_URL}"
log_info "Git branch: ${GIT_BRANCH}"

# Verify Git HTTP server is accessible
if ! curl -sf "${GIT_HTTP_URL}/HEAD" > /dev/null; then
    log_error "Git HTTP server is not accessible at ${GIT_HTTP_URL}"
    log_error "Please ensure git-http.service is running"
    exit 1
fi

log_success "Git HTTP server is accessible"

# Set network configuration
export VNET_NAME="vnet-coco-disconnected-${GUID}"
export MASTER_SUBNET_NAME="subnet-master"
export WORKER_SUBNET_NAME="subnet-worker"

cd ~/coco-pattern

# ============================================================================
# PHASE 1: Generate Install Config
# ============================================================================
log_step "Phase 1: Generating install-config.yaml"

python3 rhdp-isolated/bastion/rhdp-cluster-define-disconnected.py "${AZURE_REGION}" --upi

if [ ! -f openshift-install-upi/install-config.yaml ]; then
    log_error "Failed to generate install-config.yaml"
    exit 1
fi

log_success "Install config generated"

# Backup install-config.yaml (it gets consumed by next step)
cp openshift-install-upi/install-config.yaml openshift-install-upi/install-config.yaml.backup

# ============================================================================
# PHASE 2: Get RHCOS Image for Azure
# ============================================================================
log_step "Phase 2: Preparing RHCOS image for Azure"
log_info "OpenShift UPI requires Red Hat CoreOS (RHCOS) images"

# Get RHCOS image URL for the OpenShift version we're using
OPENSHIFT_VERSION=$(openshift-install version | grep 'openshift-install' | awk '{print $2}')
log_info "OpenShift version: ${OPENSHIFT_VERSION}"

# Extract major.minor version (e.g., 4.20)
OCP_VERSION_SHORT=$(echo "${OPENSHIFT_VERSION}" | cut -d. -f1-2)

# Get RHCOS image URL from release info
log_info "Fetching RHCOS image URL for OpenShift ${OCP_VERSION_SHORT}..."

RHCOS_IMAGE_URL=$(openshift-install coreos print-stream-json | \
    jq -r '.architectures.x86_64.artifacts.azure.formats."vhd.gz".disk.location')

if [ -z "${RHCOS_IMAGE_URL}" ] || [ "${RHCOS_IMAGE_URL}" = "null" ]; then
    log_error "Failed to get RHCOS image URL"
    log_error "This is required for UPI deployment"
    exit 1
fi

log_info "RHCOS VHD URL: ${RHCOS_IMAGE_URL}"

# Download RHCOS VHD (compressed)
RHCOS_VHD_GZ="/var/cache/oc-mirror/rhcos-azure.vhd.gz"
RHCOS_VHD="/var/cache/oc-mirror/rhcos-azure.vhd"

if [ ! -f "${RHCOS_VHD}" ]; then
    log_info "Downloading RHCOS VHD (this may take several minutes)..."
    
    if ! curl -L "${RHCOS_IMAGE_URL}" -o "${RHCOS_VHD_GZ}"; then
        log_error "Failed to download RHCOS image"
        exit 1
    fi
    
    log_info "Extracting VHD..."
    gunzip -f "${RHCOS_VHD_GZ}"
    
    log_success "RHCOS VHD ready: ${RHCOS_VHD}"
else
    log_info "Using cached RHCOS VHD: ${RHCOS_VHD}"
fi

# Upload VHD to Azure Storage and create managed image
log_info "Uploading RHCOS VHD to Azure..."

# Create storage account for VHD (if not exists)
VHD_STORAGE_ACCOUNT="vhd${GUID}"

if ! az storage account show -n "${VHD_STORAGE_ACCOUNT}" -g "${RESOURCEGROUP}" &>/dev/null; then
    log_info "Creating VHD storage account..."
    az storage account create \
        -n "${VHD_STORAGE_ACCOUNT}" \
        -g "${RESOURCEGROUP}" \
        -l "${AZURE_REGION}" \
        --sku Standard_LRS \
        --kind StorageV2
fi

VHD_STORAGE_KEY=$(az storage account keys list \
    -g "${RESOURCEGROUP}" \
    -n "${VHD_STORAGE_ACCOUNT}" \
    --query '[0].value' -o tsv)

# Create container for VHD
VHD_CONTAINER="vhds"
if ! az storage container show \
    --account-name "${VHD_STORAGE_ACCOUNT}" \
    --account-key "${VHD_STORAGE_KEY}" \
    --name "${VHD_CONTAINER}" &>/dev/null; then
    
    az storage container create \
        --account-name "${VHD_STORAGE_ACCOUNT}" \
        --account-key "${VHD_STORAGE_KEY}" \
        --name "${VHD_CONTAINER}"
fi

# Upload VHD
VHD_NAME="rhcos-${OCP_VERSION_SHORT}.vhd"
log_info "Uploading VHD to Azure Storage (this may take 10-15 minutes)..."

az storage blob upload \
    --account-name "${VHD_STORAGE_ACCOUNT}" \
    --account-key "${VHD_STORAGE_KEY}" \
    --container-name "${VHD_CONTAINER}" \
    --name "${VHD_NAME}" \
    --file "${RHCOS_VHD}" \
    --type page \
    --overwrite

VHD_URL="https://${VHD_STORAGE_ACCOUNT}.blob.core.windows.net/${VHD_CONTAINER}/${VHD_NAME}"
log_success "VHD uploaded: ${VHD_URL}"

# Create managed image from VHD
IMAGE_NAME="rhcos-${GUID}-image"
log_info "Creating managed image from VHD..."

if ! az image show -n "${IMAGE_NAME}" -g "${RESOURCEGROUP}" &>/dev/null; then
    az image create \
        -n "${IMAGE_NAME}" \
        -g "${RESOURCEGROUP}" \
        -l "${AZURE_REGION}" \
        --os-type Linux \
        --source "${VHD_URL}"
    
    log_success "Managed image created: ${IMAGE_NAME}"
else
    log_info "Managed image already exists: ${IMAGE_NAME}"
fi

# Get image ID for Terraform
RHCOS_IMAGE_ID=$(az image show -n "${IMAGE_NAME}" -g "${RESOURCEGROUP}" --query 'id' -o tsv)
export TF_VAR_rhcos_image_id="${RHCOS_IMAGE_ID}"

log_success "RHCOS image ready for deployment"

# ============================================================================
# PHASE 3: Generate Ignition Configs
# ============================================================================
log_step "Phase 3: Generating ignition configurations"
log_info "This will generate bootstrap.ign, master.ign, worker.ign"

if ! openshift-install create ignition-configs --dir=./openshift-install-upi; then
    log_error "Failed to generate ignition configs"
    exit 1
fi

log_success "Ignition configs generated:"
ls -lh openshift-install-upi/*.ign

# Extract cluster information
CLUSTER_NAME=$(jq -r '.infraID' openshift-install-upi/metadata.json)
log_info "Cluster name: ${CLUSTER_NAME}"

# ============================================================================
# PHASE 4: Upload Ignition Configs to Azure Storage
# ============================================================================
log_step "Phase 4: Uploading ignition configs to Azure Storage"

# Create storage account for ignition configs (if not exists)
STORAGE_ACCOUNT="ign${GUID}"
CONTAINER_NAME="ignition"

log_info "Storage account: ${STORAGE_ACCOUNT}"

if ! az storage account show -n "${STORAGE_ACCOUNT}" -g "${RESOURCEGROUP}" &>/dev/null; then
    log_info "Creating storage account..."
    az storage account create \
        -n "${STORAGE_ACCOUNT}" \
        -g "${RESOURCEGROUP}" \
        -l "${AZURE_REGION}" \
        --sku Standard_LRS \
        --kind StorageV2 \
        --https-only true \
        --allow-blob-public-access false
    
    log_success "Storage account created"
else
    log_info "Storage account already exists"
fi

# Get storage account key
STORAGE_KEY=$(az storage account keys list \
    -g "${RESOURCEGROUP}" \
    -n "${STORAGE_ACCOUNT}" \
    --query '[0].value' -o tsv)

# Create container
if ! az storage container show \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --name "${CONTAINER_NAME}" &>/dev/null; then
    
    log_info "Creating storage container..."
    az storage container create \
        --account-name "${STORAGE_ACCOUNT}" \
        --account-key "${STORAGE_KEY}" \
        --name "${CONTAINER_NAME}" \
        --public-access off
    
    log_success "Container created"
else
    log_info "Container already exists"
fi

# Upload ignition files
log_info "Uploading ignition configs..."
for ign_file in openshift-install-upi/*.ign; do
    filename=$(basename "${ign_file}")
    log_info "  Uploading ${filename}..."
    
    az storage blob upload \
        --account-name "${STORAGE_ACCOUNT}" \
        --account-key "${STORAGE_KEY}" \
        --container-name "${CONTAINER_NAME}" \
        --name "${filename}" \
        --file "${ign_file}" \
        --overwrite
done

log_success "Ignition configs uploaded"

# Generate SAS tokens for each ignition file (valid for 24 hours)
EXPIRY=$(date -u -d '+24 hours' '+%Y-%m-%dT%H:%MZ')
log_info "Generating SAS tokens (valid until ${EXPIRY})..."

BOOTSTRAP_URL=$(az storage blob generate-sas \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --container-name "${CONTAINER_NAME}" \
    --name "bootstrap.ign" \
    --permissions r \
    --expiry "${EXPIRY}" \
    --https-only \
    --full-uri -o tsv)

MASTER_URL=$(az storage blob generate-sas \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --container-name "${CONTAINER_NAME}" \
    --name "master.ign" \
    --permissions r \
    --expiry "${EXPIRY}" \
    --https-only \
    --full-uri -o tsv)

WORKER_URL=$(az storage blob generate-sas \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --container-name "${CONTAINER_NAME}" \
    --name "worker.ign" \
    --permissions r \
    --expiry "${EXPIRY}" \
    --https-only \
    --full-uri -o tsv)

log_success "SAS URLs generated"

# ============================================================================
# PHASE 5: Deploy VMs with Terraform
# ============================================================================
log_step "Phase 5: Deploying VMs with static IPs using Terraform"
log_info "This creates bootstrap, master, and worker VMs with precise IP control"

# Export variables for Terraform
export TF_VAR_bootstrap_ignition_url="${BOOTSTRAP_URL}"
export TF_VAR_master_ignition_url="${MASTER_URL}"
export TF_VAR_worker_ignition_url="${WORKER_URL}"
export TF_VAR_cluster_name="${CLUSTER_NAME}"
export TF_VAR_rhcos_image_id="${RHCOS_IMAGE_ID}"
export ARM_SUBSCRIPTION_ID="${SUBSCRIPTION}"
export ARM_CLIENT_ID="${CLIENT_ID}"
export ARM_CLIENT_SECRET="${PASSWORD}"
export ARM_TENANT_ID="${TENANT}"

cd ~/coco-pattern/rhdp-isolated/terraform-upi

# Initialize Terraform (if needed)
if [ ! -d .terraform ]; then
    log_info "Initializing Terraform..."
    terraform init
fi

# Create Terraform tfvars file
cat > terraform.tfvars <<EOF
# UPI Cluster Configuration
guid = "${GUID}"
resource_group_name = "${RESOURCEGROUP}"
region = "${AZURE_REGION}"
cluster_name = "${CLUSTER_NAME}"

# Network Configuration
vnet_name = "${VNET_NAME}"
master_subnet_name = "${MASTER_SUBNET_NAME}"
worker_subnet_name = "${WORKER_SUBNET_NAME}"

# Static IP Assignments (critical for UPI)
bootstrap_ip = "10.0.10.4"
master_ips = ["10.0.10.5", "10.0.10.6", "10.0.10.7"]
worker_ips = ["10.0.20.4", "10.0.20.5"]

# Ignition URLs
bootstrap_ignition_url = "${BOOTSTRAP_URL}"
master_ignition_url = "${MASTER_URL}"
worker_ignition_url = "${WORKER_URL}"

# SSH Key
ssh_public_key = "$(cat ~/.ssh/id_rsa.pub)"
EOF

log_info "Terraform configuration created"
log_info "Planning Terraform deployment..."

terraform plan -out=tfplan

log_info "Applying Terraform configuration..."
log_warn "This will create VMs and may take 10-15 minutes"

if ! terraform apply tfplan; then
    log_error "Terraform apply failed"
    exit 1
fi

log_success "VMs deployed successfully"

cd ~/coco-pattern

# ============================================================================
# PHASE 6: Monitor Bootstrap Completion
# ============================================================================
log_step "Phase 6: Monitoring bootstrap completion"
log_info "Waiting for bootstrap to complete (typically 20-30 minutes)"

if ! openshift-install wait-for bootstrap-complete --dir=./openshift-install-upi; then
    log_error "Bootstrap failed"
    log_error "Check bootstrap VM logs for details"
    exit 1
fi

log_success "Bootstrap completed successfully!"

# ============================================================================
# PHASE 7: Remove Bootstrap Resources
# ============================================================================
log_step "Phase 7: Removing bootstrap resources"
log_info "Bootstrap is no longer needed, cleaning up..."

cd ~/coco-pattern/rhdp-isolated/terraform-upi

# Remove bootstrap VM
terraform destroy -target=azurerm_virtual_machine.bootstrap -auto-approve

log_success "Bootstrap VM removed"

cd ~/coco-pattern

# ============================================================================
# PHASE 8: Complete Installation
# ============================================================================
log_step "Phase 8: Completing cluster installation"
log_info "Waiting for cluster operators to stabilize (typically 20-30 minutes)"

if ! openshift-install wait-for install-complete --dir=./openshift-install-upi; then
    log_error "Cluster installation failed"
    exit 1
fi

log_success "Cluster installation complete!"

# ============================================================================
# PHASE 9: Install Validated Pattern
# ============================================================================
log_step "Phase 9: Installing CoCo Validated Pattern"
log_info "Using bastion Git server: ${GIT_HTTP_URL}"

export KUBECONFIG=~/coco-pattern/openshift-install-upi/auth/kubeconfig

# Verify cluster access
if ! oc whoami &>/dev/null; then
    log_error "Cannot connect to cluster"
    exit 1
fi

log_info "Connected to cluster as: $(oc whoami)"

# Install pattern with Helm overrides for disconnected environment
cd ~/coco-pattern

log_info "Installing pattern framework..."

EXTRA_HELM_OPTS=""
EXTRA_HELM_OPTS+=" --set main.multiSourceConfig.helmRepoUrl=oci://${ACR_LOGIN_SERVER}/hybridcloudpatterns"
EXTRA_HELM_OPTS+=" --set main.git.repoURL=${GIT_HTTP_URL}"
EXTRA_HELM_OPTS+=" --set main.git.revision=${GIT_BRANCH}"

export EXTRA_HELM_OPTS

log_info "Helm options: ${EXTRA_HELM_OPTS}"

if ! ./pattern.sh make install; then
    log_error "Pattern installation failed"
    exit 1
fi

log_success "Pattern framework installed"

log_info "Loading secrets..."
if ! ./pattern.sh make load-secrets; then
    log_warn "Failed to load secrets (may need manual intervention)"
fi

# ============================================================================
# INSTALLATION COMPLETE
# ============================================================================
log_step "Installation Complete!"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  OpenShift UPI Cluster Successfully Deployed!"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Cluster Details:"
echo "  Name:      coco-${GUID}"
echo "  Region:    ${AZURE_REGION}"
echo "  Infra ID:  ${CLUSTER_NAME}"
echo ""
echo "Access Information:"
echo "  Kubeconfig: ~/coco-pattern/openshift-install-upi/auth/kubeconfig"
echo "  Console:    https://console-openshift-console.apps.coco.${GUID}.azure.redhatworkshops.io"
echo ""
echo "Credentials:"
echo "  Username:   kubeadmin"
echo "  Password:   $(cat ~/coco-pattern/openshift-install-upi/auth/kubeadmin-password 2>/dev/null || echo 'See auth/kubeadmin-password')"
echo ""
echo "VM IP Addresses:"
echo "  Bootstrap:  10.0.10.4 (removed after bootstrap)"
echo "  Master-0:   10.0.10.5"
echo "  Master-1:   10.0.10.6"
echo "  Master-2:   10.0.10.7"
echo "  Worker-0:   10.0.20.4"
echo "  Worker-1:   10.0.20.5"
echo ""
echo "Pattern Repository:"
echo "  Git URL:    ${GIT_HTTP_URL}"
echo "  Branch:     ${GIT_BRANCH}"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo ""

log_info "To access the cluster:"
echo "  export KUBECONFIG=~/coco-pattern/openshift-install-upi/auth/kubeconfig"
echo "  oc get nodes"
echo "  oc get co"

