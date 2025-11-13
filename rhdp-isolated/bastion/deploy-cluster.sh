#!/bin/bash
# SPDX-FileCopyrightText: 2024-present Red Hat Inc
# SPDX-License-Identifier: Apache-2.0
#
# Minimal OpenShift UPI Deployment Orchestration
# Infrastructure is handled by Terraform - this script only orchestrates OpenShift operations

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
REQUIRED_VARS=("GUID" "RESOURCEGROUP" "REGISTRY_URL" "SUBSCRIPTION" "CLIENT_ID" "PASSWORD" "TENANT")
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

log_step "OpenShift UPI Deployment - Terraform-First Approach"
log_info "Cluster: coco-${GUID}"
log_info "Region: ${AZURE_REGION}"
log_info "Registry: ${REGISTRY_URL}"
log_info "Mode: Minimal orchestration, Terraform-managed infrastructure"

# ============================================================================
# STEP 0: Ensure Mirroring Complete (Auto-run if needed)
# ============================================================================
log_step "Step 0: Checking image mirroring status"

if [ ! -d ~/coco-pattern/cluster-resources ] || [ -z "$(ls -A ~/coco-pattern/cluster-resources 2>/dev/null)" ]; then
    log_warn "Mirroring not complete, running mirror.sh automatically..."
    log_warn "This will take 2-4 hours on first run..."
    
    ~/coco-pattern/rhdp-isolated/bastion/mirror.sh
    
    if [ $? -ne 0 ]; then
        log_error "Mirroring failed"
        exit 1
    fi
    
    log_success "Mirroring completed"
else
    log_success "Mirroring already complete ($(ls ~/coco-pattern/cluster-resources/*.yaml | wc -l) manifest files found)"
fi

# ============================================================================
# STEP 1: Prepare RHCOS Image (Terraform)
# ============================================================================
log_step "Step 1: Preparing RHCOS image with Terraform"

cd ~/coco-pattern/rhdp-isolated/terraform-rhcos-image

# Set Azure credentials for Terraform
export ARM_SUBSCRIPTION_ID="${SUBSCRIPTION}"
export ARM_CLIENT_ID="${CLIENT_ID}"
export ARM_CLIENT_SECRET="${PASSWORD}"
export ARM_TENANT_ID="${TENANT}"

# Initialize Terraform
if [ ! -d .terraform ]; then
    log_info "Initializing Terraform..."
    terraform init
fi

# Create tfvars
cat > terraform.tfvars <<EOF
guid                 = "${GUID}"
resource_group_name  = "${RESOURCEGROUP}"
region               = "${AZURE_REGION}"
openshift_version    = "4.20"

# Azure Auth
subscription_id = "${SUBSCRIPTION}"
client_id       = "${CLIENT_ID}"
client_secret   = "${PASSWORD}"
tenant_id       = "${TENANT}"
EOF

# Apply
log_info "Creating RHCOS managed image..."
terraform apply -auto-approve

RHCOS_IMAGE_ID=$(terraform output -raw image_id)
log_success "RHCOS image ready: $(terraform output -raw image_name)"

# ============================================================================
# STEP 2: Generate OpenShift Install Config
# ============================================================================
log_step "Step 2: Generating install-config.yaml"

cd ~/coco-pattern

python3 rhdp-isolated/bastion/rhdp-cluster-define-disconnected.py "${AZURE_REGION}" --upi

if [ ! -f openshift-install-upi/install-config.yaml ]; then
    log_error "Failed to generate install-config.yaml"
    exit 1
fi

# Backup install-config (it gets consumed)
cp openshift-install-upi/install-config.yaml openshift-install-upi/install-config.yaml.backup
log_success "Install config generated"

# ============================================================================
# STEP 3: Generate Ignition Configs
# ============================================================================
log_step "Step 3: Generating ignition configurations"

if ! openshift-install create ignition-configs --dir=./openshift-install-upi; then
    log_error "Failed to generate ignition configs"
    exit 1
fi

CLUSTER_NAME=$(jq -r '.infraID' openshift-install-upi/metadata.json)
log_info "Cluster infraID: ${CLUSTER_NAME}"
log_success "Ignition configs generated"

# ============================================================================
# STEP 4: Deploy Complete UPI Infrastructure (Terraform)
# ============================================================================
log_step "Step 4: Deploying UPI infrastructure with Terraform"

cd ~/coco-pattern/rhdp-isolated/terraform-upi-complete

# Initialize if needed
if [ ! -d .terraform ]; then
    log_info "Initializing Terraform..."
    terraform init
fi

# Construct bastion ignition URLs
BASTION_IP="10.0.1.4"
IGNITION_PORT="8081"

BOOTSTRAP_URL="http://${BASTION_IP}:${IGNITION_PORT}/bootstrap.ign"
MASTER_URL="http://${BASTION_IP}:${IGNITION_PORT}/master.ign"
WORKER_URL="http://${BASTION_IP}:${IGNITION_PORT}/worker.ign"

# Create tfvars
CLUSTER_DOMAIN="coco.${GUID}.azure.redhatworkshops.io"
VNET_NAME="vnet-coco-disconnected-${GUID}"
MASTER_SUBNET_NAME="subnet-master"
WORKER_SUBNET_NAME="subnet-worker"

cat > terraform.tfvars <<EOF
# UPI Cluster Configuration
guid                = "${GUID}"
resource_group_name = "${RESOURCEGROUP}"
region              = "${AZURE_REGION}"
cluster_name        = "${CLUSTER_NAME}"
cluster_domain      = "${CLUSTER_DOMAIN}"

# Network Configuration
vnet_name           = "${VNET_NAME}"
master_subnet_name  = "${MASTER_SUBNET_NAME}"
worker_subnet_name  = "${WORKER_SUBNET_NAME}"

# Bastion and Ignition
bastion_ip          = "${BASTION_IP}"
local_ignition_dir  = "$(cd ~/coco-pattern && pwd)/openshift-install-upi"

# Ignition URLs (bastion HTTP server)
bootstrap_ignition_url = "${BOOTSTRAP_URL}"
master_ignition_url    = "${MASTER_URL}"
worker_ignition_url    = "${WORKER_URL}"

# RHCOS Image
rhcos_image_id = "${RHCOS_IMAGE_ID}"

# SSH Key
ssh_public_key = "$(cat ~/.ssh/id_rsa.pub)"

# Azure Auth
subscription_id = "${SUBSCRIPTION}"
client_id       = "${CLIENT_ID}"
client_secret   = "${PASSWORD}"
tenant_id       = "${TENANT}"
EOF

log_info "Planning Terraform deployment..."
terraform plan -out=tfplan

log_info "Applying Terraform configuration..."
log_warn "This creates DNS, LBs, copies ignition to bastion, and provisions VMs (~15-20 min)"

if ! terraform apply tfplan; then
    log_error "Terraform apply failed"
    exit 1
fi

log_success "UPI infrastructure deployed successfully"

# ============================================================================
# STEP 5: Wait for Bootstrap Complete
# ============================================================================
log_step "Step 5: Monitoring bootstrap completion"

cd ~/coco-pattern

export KUBECONFIG=./openshift-install-upi/auth/kubeconfig

log_info "Waiting for bootstrap to complete (up to 30 minutes)..."
log_info "You can monitor progress in another terminal with:"
log_info "  ssh core@$(terraform -chdir=rhdp-isolated/terraform-upi-complete output -raw bootstrap_public_ip)"
log_info "  journalctl -b -f -u bootkube.service"

if ! openshift-install wait-for bootstrap-complete --dir=./openshift-install-upi --log-level=info; then
    log_error "Bootstrap failed"
    exit 1
fi

log_success "Bootstrap completed successfully!"

# ============================================================================
# STEP 6: Remove Bootstrap VM
# ============================================================================
log_step "Step 6: Removing bootstrap VM"

cd ~/coco-pattern/rhdp-isolated/terraform-upi-complete

terraform destroy -target=azurerm_linux_virtual_machine.bootstrap \
                  -target=azurerm_network_interface.bootstrap \
                  -target=azurerm_public_ip.bootstrap \
                  -target=azurerm_network_interface_backend_address_pool_association.bootstrap \
                  -auto-approve

log_success "Bootstrap VM removed"

# ============================================================================
# STEP 7: Approve CSRs and Complete Installation
# ============================================================================
log_step "Step 7: Approving CSRs and completing installation"

cd ~/coco-pattern

log_info "Approving node CSRs..."

# Approve pending CSRs in a loop (masters and workers need this)
for i in {1..20}; do
    log_info "CSR approval attempt $i/20..."
    
    PENDING_CSRS=$(oc get csr -o json | jq -r '.items[] | select(.status == {}) | .metadata.name')
    
    if [ -n "$PENDING_CSRS" ]; then
        echo "$PENDING_CSRS" | xargs oc adm certificate approve || true
        log_info "Approved $(echo "$PENDING_CSRS" | wc -l) CSRs"
    fi
    
    # Check if all nodes are ready
    READY_NODES=$(oc get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
    TOTAL_NODES=6  # 3 masters + 3 workers
    
    if [ "$READY_NODES" -eq "$TOTAL_NODES" ]; then
        log_success "All nodes are Ready!"
        break
    fi
    
    sleep 30
done

log_info "Waiting for install to complete..."
if ! openshift-install wait-for install-complete --dir=./openshift-install-upi --log-level=info; then
    log_error "Installation failed"
    exit 1
fi

log_success "Cluster installation complete!"

# ============================================================================
# STEP 8: Install CoCo Validated Pattern
# ============================================================================
log_step "Step 8: Installing CoCo Validated Pattern"

# Get bastion private IP for Git server
BASTION_PRIVATE_IP="10.0.1.4"
GIT_HTTP_URL="http://${BASTION_PRIVATE_IP}:8080/coco-pattern"
GIT_BRANCH=$(cd ~/coco-pattern && git branch --show-current)

log_info "Pattern Git URL: ${GIT_HTTP_URL}"
log_info "Pattern branch: ${GIT_BRANCH}"

# Install pattern with Helm pointing to bastion Git and ACR
cd ~/coco-pattern

# Create pattern namespace
oc create namespace openshift-gitops || true

# Set Helm values for disconnected deployment
EXTRA_HELM_OPTS="
  --set main.git.repoURL=${GIT_HTTP_URL} \
  --set main.git.revision=${GIT_BRANCH} \
  --set main.multiSourceConfig.helmRepoUrl=oci://${REGISTRY_URL}/hybridcloudpatterns
"

log_info "Deploying pattern with bastion-served Git and registry images..."

if ! ./pattern.sh make install EXTRA_HELM_OPTS="${EXTRA_HELM_OPTS}"; then
    log_error "Pattern installation failed"
    log_warn "You can manually retry with:"
    log_warn "  cd ~/coco-pattern"
    log_warn "  ./pattern.sh make install EXTRA_HELM_OPTS=\"${EXTRA_HELM_OPTS}\""
    exit 1
fi

log_success "Pattern deployed successfully!"

# ============================================================================
# DEPLOYMENT COMPLETE
# ============================================================================
log_step "Deployment Complete!"

log_success "OpenShift cluster is ready:"
log_info "  Console: https://console-openshift-console.apps.${CLUSTER_NAME}.${CLUSTER_DOMAIN}"
log_info "  Kubeconfig: $(pwd)/openshift-install-upi/auth/kubeconfig"
log_info "  Username: kubeadmin"
log_info "  Password: $(cat openshift-install-upi/auth/kubeadmin-password)"

log_success "CoCo pattern installed (monitor with ArgoCD)"

log_info "Verify disconnected deployment:"
log_info "  1. All ignition fetched from: http://${BASTION_IP}:8081/"
log_info "  2. All images pulled from: ${REGISTRY_URL}"
log_info "  3. All Git operations from: ${GIT_HTTP_URL}"
log_info "  4. Azure Cloud APIs accessible for cluster management only"

echo ""
log_success "🎉 Truly disconnected OpenShift deployment successful!"

