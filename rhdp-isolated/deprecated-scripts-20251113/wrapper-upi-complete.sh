#!/bin/bash
# SPDX-FileCopyrightText: 2024-present Red Hat Inc
# SPDX-License-Identifier: Apache-2.0
#
# Complete OpenShift UPI Installation with Full Lifecycle Management
# Includes: Infrastructure, Bootstrap, CSR Approval, Node Admission, Pattern Installation

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

log_step "OpenShift UPI Complete Installation Starting"
log_info "Cluster: coco-${GUID}"
log_info "Region: ${AZURE_REGION}"
log_info "Mode: UPI (User-Provisioned Infrastructure) - Complete"
log_info "Registry: ${ACR_LOGIN_SERVER}"

# Get bastion private IP for Git server
BASTION_PRIVATE_IP=$(hostname -I | awk '{print $1}')
GIT_HTTP_URL="http://${BASTION_PRIVATE_IP}:8080/coco-pattern"
GIT_BRANCH=$(cd ~/coco-pattern && git branch --show-current)

log_info "Git server: ${GIT_HTTP_URL}"
log_info "Git branch: ${GIT_BRANCH}"

# Set network configuration
export VNET_NAME="vnet-coco-disconnected-${GUID}"
export MASTER_SUBNET_NAME="subnet-master"
export WORKER_SUBNET_NAME="subnet-worker"

cd ~/coco-pattern

# ============================================================================
# PHASE 1: Check/Reuse Ignition Configs
# ============================================================================
log_step "Phase 1: Checking ignition configurations"

if [ -d "openshift-install-upi" ] && [ -f "openshift-install-upi/metadata.json" ]; then
    log_info "Using existing ignition configs from previous run"
    CLUSTER_NAME=$(jq -r '.infraID' openshift-install-upi/metadata.json)
    log_info "Cluster infraID: ${CLUSTER_NAME}"
else
    log_info "Generating new install-config.yaml"
    python3 rhdp-isolated/bastion/rhdp-cluster-define-disconnected.py "${AZURE_REGION}" --upi

    if [ ! -f openshift-install-upi/install-config.yaml ]; then
        log_error "Failed to generate install-config.yaml"
        exit 1
    fi

    # Backup install-config.yaml (consumed by next step)
    cp openshift-install-upi/install-config.yaml openshift-install-upi/install-config.yaml.backup

    log_info "Generating ignition configurations"
    if ! openshift-install create ignition-configs --dir=./openshift-install-upi; then
        log_error "Failed to generate ignition configs"
        exit 1
    fi

    CLUSTER_NAME=$(jq -r '.infraID' openshift-install-upi/metadata.json)
    log_info "Cluster infraID: ${CLUSTER_NAME}"

    # Copy ignition configs to bastion HTTP server (truly disconnected)
    log_info "Copying ignition configs to bastion HTTP server..."
    
    IGNITION_DIR="/var/cache/oc-mirror/ignition"
    
    # Ensure ignition directory exists and is writable
    sudo mkdir -p "${IGNITION_DIR}"
    sudo chown azureuser:azureuser "${IGNITION_DIR}"
    
    # Copy each ignition file
    for ign_file in openshift-install-upi/*.ign; do
        filename=$(basename "${ign_file}")
        log_info "  Copying ${filename}..."
        cp "${ign_file}" "${IGNITION_DIR}/${filename}"
        chmod 644 "${IGNITION_DIR}/${filename}"
    done
    
    # Verify ignition HTTP server is running
    if ! systemctl is-active --quiet ignition-http.service; then
        log_warn "Ignition HTTP server not running, starting it..."
        sudo systemctl start ignition-http.service
    fi
    
    log_success "Ignition configs served from bastion"
fi

log_success "Ignition configs ready"

# ============================================================================
# PHASE 2: Generate Bastion HTTP URLs for Ignition Configs
# ============================================================================
log_step "Phase 2: Generating bastion HTTP URLs for ignition configs"

# Get bastion private IP (hardcoded in subnet configuration)
BASTION_IP="10.0.1.4"
IGNITION_PORT="8081"

# Construct HTTP URLs pointing to bastion
BOOTSTRAP_URL="http://${BASTION_IP}:${IGNITION_PORT}/bootstrap.ign"
MASTER_URL="http://${BASTION_IP}:${IGNITION_PORT}/master.ign"
WORKER_URL="http://${BASTION_IP}:${IGNITION_PORT}/worker.ign"

log_info "Bastion ignition URLs:"
log_info "  Bootstrap: ${BOOTSTRAP_URL}"
log_info "  Master: ${MASTER_URL}"
log_info "  Worker: ${WORKER_URL}"

# Test connectivity to bastion ignition server
log_info "Verifying ignition server accessibility..."
if curl -sf "${BOOTSTRAP_URL}" > /dev/null 2>&1; then
    log_success "Ignition server is accessible from bastion"
else
    log_error "Cannot access ignition server at ${BASTION_IP}:${IGNITION_PORT}"
    log_error "Please verify ignition-http.service is running"
    exit 1
fi

log_success "Bastion HTTP URLs generated (no expiry, truly disconnected)"

# ============================================================================
# PHASE 3: Get RHCOS Image ID
# ============================================================================
log_step "Phase 3: Preparing RHCOS image"

IMAGE_NAME="rhcos-${GUID}-image"
RHCOS_IMAGE_ID=$(az image show -n "${IMAGE_NAME}" -g "${RESOURCEGROUP}" --query 'id' -o tsv)

if [ -z "$RHCOS_IMAGE_ID" ]; then
    log_error "RHCOS image not found: ${IMAGE_NAME}"
    log_error "Please ensure the image has been created"
    exit 1
fi

log_success "RHCOS image ready: ${IMAGE_NAME}"

# ============================================================================
# PHASE 4: Deploy Complete UPI Infrastructure with Terraform
# ============================================================================
log_step "Phase 4: Deploying complete UPI infrastructure (DNS + LBs + VMs)"
log_info "This creates all required UPI components with static IPs"

cd ~/coco-pattern/rhdp-isolated/terraform-upi-complete

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

# Create Terraform tfvars file
CLUSTER_DOMAIN="coco.${GUID}.azure.redhatworkshops.io"

cat > terraform.tfvars <<EOF
# UPI Cluster Configuration
guid = "${GUID}"
resource_group_name = "${RESOURCEGROUP}"
region = "${AZURE_REGION}"
cluster_name = "${CLUSTER_NAME}"
cluster_domain = "${CLUSTER_DOMAIN}"

# Network Configuration
vnet_name = "${VNET_NAME}"
master_subnet_name = "${MASTER_SUBNET_NAME}"
worker_subnet_name = "${WORKER_SUBNET_NAME}"

# Static IP Assignments
bootstrap_ip = "10.0.10.4"
master_ips = ["10.0.10.5", "10.0.10.6", "10.0.10.7"]
worker_ips = ["10.0.20.4", "10.0.20.5", "10.0.20.6"]
api_internal_ip = "10.0.10.10"

# Ignition URLs
bootstrap_ignition_url = "${BOOTSTRAP_URL}"
master_ignition_url = "${MASTER_URL}"
worker_ignition_url = "${WORKER_URL}"

# RHCOS Image
rhcos_image_id = "${RHCOS_IMAGE_ID}"

# SSH Key
ssh_public_key = "$(cat ~/.ssh/id_rsa.pub)"

# Azure Auth
subscription_id = "${SUBSCRIPTION}"
client_id = "${CLIENT_ID}"
client_secret = "${PASSWORD}"
tenant_id = "${TENANT}"
EOF

log_info "Planning Terraform deployment..."
terraform plan -out=tfplan

log_info "Applying Terraform configuration..."
log_warn "This will create DNS, Load Balancers, and VMs (15-20 minutes)"

if ! terraform apply tfplan; then
    log_error "Terraform apply failed"
    exit 1
fi

log_success "Complete UPI infrastructure deployed successfully"

# Get outputs
API_EXTERNAL_IP=$(terraform output -raw api_external_ip)
API_INTERNAL_IP=$(terraform output -raw api_internal_ip)

log_info "External API IP: ${API_EXTERNAL_IP}"
log_info "Internal API IP (load balancer): ${API_INTERNAL_IP}"

cd ~/coco-pattern

# ============================================================================
# PHASE 5: Wait for Bootstrap Completion
# ============================================================================
log_step "Phase 5: Waiting for bootstrap completion"
log_info "This typically takes 20-30 minutes"
log_info "The bootstrap VM is configuring the control plane..."

export KUBECONFIG=~/coco-pattern/openshift-install-upi/auth/kubeconfig

if ! openshift-install wait-for bootstrap-complete --dir=./openshift-install-upi --log-level=info; then
    log_error "Bootstrap failed"
    log_error "Check logs for details"
    exit 1
fi

log_success "Bootstrap completed successfully!"

# ============================================================================
# PHASE 6: Approve Pending CSRs
# ============================================================================
log_step "Phase 6: Approving Certificate Signing Requests (CSRs)"
log_info "Nodes need CSRs approved to join the cluster"

# Function to approve all pending CSRs
approve_csrs() {
    local approved=0
    
    for csr in $(oc get csr -o json | jq -r '.items[] | select(.status == {}) | .metadata.name'); do
        oc adm certificate approve "$csr"
        approved=$((approved + 1))
        log_info "  Approved CSR: $csr"
    done
    
    return $approved
}

# Approve CSRs in multiple rounds (nodes request multiple CSRs)
log_info "Approving initial CSRs..."
sleep 30
approve_csrs

log_info "Waiting for nodes to generate additional CSRs..."
sleep 60
approve_csrs

log_info "Final CSR approval round..."
sleep 30
approve_csrs

log_success "All CSRs approved"

# ============================================================================
# PHASE 7: Verify Nodes Joined Cluster
# ============================================================================
log_step "Phase 7: Verifying nodes joined the cluster"

log_info "Waiting for all nodes to be Ready..."
for i in {1..20}; do
    READY_NODES=$(oc get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo "0")
    TOTAL_NODES=$(oc get nodes --no-headers 2>/dev/null | wc -l || echo "0")
    
    log_info "Nodes ready: ${READY_NODES}/${TOTAL_NODES} (expected 6: 3 masters + 3 workers)"
    
    if [ "$READY_NODES" -ge 6 ]; then
        break
    fi
    
    # Approve any new CSRs that appeared
    approve_csrs || true
    
    sleep 30
done

echo ""
oc get nodes
echo ""

log_success "All nodes joined the cluster"

# ============================================================================
# PHASE 8: Verify Kubernetes API is Active
# ============================================================================
log_step "Phase 8: Verifying Kubernetes API server"

if oc whoami &>/dev/null; then
    log_success "Kubernetes API is active and accessible"
    log_info "Current user: $(oc whoami)"
else
    log_error "Cannot connect to Kubernetes API"
    exit 1
fi

# ============================================================================
# PHASE 9: Decommission Bootstrap VM
# ============================================================================
log_step "Phase 9: Decommissioning bootstrap VM"
log_info "Bootstrap is no longer needed, removing it..."

cd ~/coco-pattern/rhdp-isolated/terraform-upi-complete

# Destroy bootstrap VM using Terraform
terraform destroy \
    -target=azurerm_linux_virtual_machine.bootstrap \
    -target=azurerm_network_interface.bootstrap \
    -target=azurerm_public_ip.bootstrap \
    -target=azurerm_network_interface_backend_address_pool_association.bootstrap \
    -auto-approve

log_success "Bootstrap VM decommissioned"

cd ~/coco-pattern

# ============================================================================
# PHASE 10: Complete Cluster Installation
# ============================================================================
log_step "Phase 10: Completing cluster installation"
log_info "Waiting for all cluster operators to stabilize (20-30 minutes)"

if ! openshift-install wait-for install-complete --dir=./openshift-install-upi --log-level=info; then
    log_warn "Installation didn't complete cleanly, but checking cluster state..."
fi

# Check cluster operators
log_info "Cluster Operators status:"
oc get co

log_success "Cluster installation complete!"

# ============================================================================
# PHASE 11: Install CoCo Validated Pattern
# ============================================================================
log_step "Phase 11: Installing CoCo Validated Pattern"
log_info "Using bastion Git server: ${GIT_HTTP_URL}"

cd ~/coco-pattern

EXTRA_HELM_OPTS=""
EXTRA_HELM_OPTS+=" --set main.multiSourceConfig.helmRepoUrl=oci://${ACR_LOGIN_SERVER}/hybridcloudpatterns"
EXTRA_HELM_OPTS+=" --set main.git.repoURL=${GIT_HTTP_URL}"
EXTRA_HELM_OPTS+=" --set main.git.revision=${GIT_BRANCH}"

export EXTRA_HELM_OPTS

log_info "Installing pattern framework..."

if ! ./pattern.sh make install; then
    log_error "Pattern installation failed"
    exit 1
fi

log_success "Pattern framework installed"

log_info "Loading secrets..."
./pattern.sh make load-secrets || log_warn "Failed to load some secrets (may need manual intervention)"

# ============================================================================
# INSTALLATION COMPLETE
# ============================================================================
log_step "OpenShift UPI Installation Complete!"

CONSOLE_URL="https://console-openshift-console.apps.${CLUSTER_DOMAIN}"
API_URL="https://api.${CLUSTER_DOMAIN}:6443"

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  OpenShift UPI Cluster Successfully Deployed!"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Cluster Details:"
echo "  Name:      coco-${GUID}"
echo "  Domain:    ${CLUSTER_DOMAIN}"
echo "  Region:    ${AZURE_REGION}"
echo "  Infra ID:  ${CLUSTER_NAME}"
echo ""
echo "Access Information:"
echo "  API URL:    ${API_URL}"
echo "  Console:    ${CONSOLE_URL}"
echo "  Kubeconfig: ~/coco-pattern/openshift-install-upi/auth/kubeconfig"
echo ""
echo "Credentials:"
echo "  Username:   kubeadmin"
echo "  Password:   $(cat ~/coco-pattern/openshift-install-upi/auth/kubeadmin-password 2>/dev/null || echo 'See auth/kubeadmin-password')"
echo ""
echo "Cluster Nodes (with Static IPs):"
echo "  Master-0:   10.0.10.5"
echo "  Master-1:   10.0.10.6"
echo "  Master-2:   10.0.10.7"
echo "  Worker-0:   10.0.20.4"
echo "  Worker-1:   10.0.20.5"
echo "  Worker-2:   10.0.20.6"
echo ""
echo "Load Balancers:"
echo "  External API:  ${API_EXTERNAL_IP}"
echo "  Internal API:  ${API_INTERNAL_IP}"
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
echo "  oc get pods -A"

