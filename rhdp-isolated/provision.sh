#!/usr/bin/env bash
# Stage 1: Provision disconnected infrastructure from developer workstation
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Check if required argument is provided
if [ "$#" -ne 1 ]; then
    log_error "Exactly one argument is required."
    echo "Usage: $0 {azure-region-code}"
    echo "Example: $0 eastus"
    exit 1
fi

AZURE_REGION=$1

log_info "Provisioning disconnected infrastructure for region: ${AZURE_REGION}"

# Validate required environment variables (RHDP style)
required_vars=("GUID" "CLIENT_ID" "PASSWORD" "TENANT" "SUBSCRIPTION" "RESOURCEGROUP")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log_error "Required environment variable '${var}' is not set"
        exit 1
    fi
done

log_info "All required environment variables are set"

# Export ARM_ variables for Terraform Azure provider
export ARM_CLIENT_ID="${CLIENT_ID}"
export ARM_CLIENT_SECRET="${PASSWORD}"
export ARM_TENANT_ID="${TENANT}"
export ARM_SUBSCRIPTION_ID="${SUBSCRIPTION}"

log_info "Azure authentication configured for Terraform"

# Check for SSH key
SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
SSH_PUB_KEY_PATH="${HOME}/.ssh/id_rsa.pub"

if [ ! -f "${SSH_KEY_PATH}" ] || [ ! -f "${SSH_PUB_KEY_PATH}" ]; then
    log_warn "SSH key not found at ${SSH_KEY_PATH}"
    log_info "Generating SSH key..."
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH}" -N "" -C "coco-disconnected-bastion"
    log_info "SSH key generated"
fi

# Check for Terraform
if ! command -v terraform &> /dev/null; then
    log_error "Terraform is not installed. Please install Terraform >= 1.0"
    exit 1
fi

log_info "Terraform found: $(terraform version | head -n1)"

# Detect current git repository details
PATTERN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PATTERN_ROOT}"

GIT_REMOTE=$(git config --get remote.origin.url || echo "")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD || echo "main")

# Convert SSH URL to HTTPS if needed (bastion can't use SSH without keys)
if [[ "$GIT_REMOTE" =~ ^git@ ]]; then
    GIT_REMOTE=$(echo "$GIT_REMOTE" | sed -E 's|^git@([^:]+):(.+)$|https://\1/\2|')
    log_info "Converted git remote to HTTPS: ${GIT_REMOTE}"
fi

log_info "Git remote: ${GIT_REMOTE}"
log_info "Git branch: ${GIT_BRANCH}"

# Create terraform.tfvars with ALL variables for self-contained cloud-init
log_info "Creating terraform.tfvars from environment variables"
cat > "${TERRAFORM_DIR}/terraform.tfvars" <<EOF
# Infrastructure
region              = "${AZURE_REGION}"
resource_group_name = "${RESOURCEGROUP}"
guid                = "${GUID}"

# Azure Service Principal (for cloud-init bastion configuration)
subscription_id  = "${SUBSCRIPTION}"
client_id        = "${CLIENT_ID}"
client_secret    = "${PASSWORD}"
tenant_id        = "${TENANT}"

# Git Repository (for cloud-init pattern cloning)
git_remote_url = "${GIT_REMOTE}"
git_branch     = "${GIT_BRANCH}"

# Tags
tags = {
  pattern    = "coco-disconnected"
  managed_by = "terraform"
  guid       = "${GUID}"
}
EOF

log_info "terraform.tfvars created with self-contained cloud-init variables"

# Navigate to terraform directory
cd "${TERRAFORM_DIR}"

# Initialize Terraform
log_info "Initializing Terraform..."
terraform init

# Validate configuration
log_info "Validating Terraform configuration..."
terraform validate

# Plan
log_info "Creating Terraform plan..."
terraform plan -out=tfplan

# Apply
log_info "Applying Terraform configuration..."
log_warn "This will create Azure resources. Press Ctrl+C within 10 seconds to cancel..."
sleep 10

terraform apply tfplan

# Get outputs
log_info "Retrieving outputs..."
BASTION_IP=$(terraform output -raw bastion_public_ip)
BASTION_USER=$(terraform output -raw bastion_admin_username)
REGISTRY_URL=$(terraform output -raw bastion_registry_url)

# Save outputs to file for later use
OUTPUTS_FILE="${SCRIPT_DIR}/infrastructure-outputs.env"
log_info "Saving outputs to ${OUTPUTS_FILE}"

cat > "${OUTPUTS_FILE}" <<EOF
# Infrastructure outputs from Terraform
# Source this file to use these variables

export BASTION_IP="${BASTION_IP}"
export BASTION_USER="${BASTION_USER}"
export REGISTRY_URL="${REGISTRY_URL}"
export AZURE_REGION="${AZURE_REGION}"
export GUID="${GUID}"
export RESOURCEGROUP="${RESOURCEGROUP}"
export CLIENT_ID="${CLIENT_ID}"
export PASSWORD="${PASSWORD}"
export TENANT="${TENANT}"
export SUBSCRIPTION="${SUBSCRIPTION}"
EOF

chmod 600 "${OUTPUTS_FILE}"

log_info ""
log_info "=========================================="
log_info "Infrastructure provisioning complete!"
log_info "=========================================="
log_info ""
log_info "Bastion Host: ${BASTION_USER}@${BASTION_IP}"
log_info "Container Registry: ${REGISTRY_URL} (bastion-hosted)"
log_info ""
log_info "Cloud-init configured on bastion:"
log_info "  ✓ Container registry (port 5000)"
log_info "  ✓ Git HTTP server (port 8080)"
log_info "  ✓ Ignition HTTP server (port 8081)"
log_info "  ✓ Azure credentials, SSH key, pattern repo"
log_info ""
log_info "Next steps:"
log_info "1. Verify bastion configuration (optional):"
log_info "   ./configure-bastion.sh"
log_info ""
log_info "2. Copy pull secret to bastion:"
log_info "   scp ~/pull-secret.json ${BASTION_USER}@${BASTION_IP}:~/"
log_info ""
log_info "3. SSH to bastion and deploy:"
log_info "   ssh ${BASTION_USER}@${BASTION_IP}"
log_info "   cd ~/coco-pattern"
log_info "   ./rhdp-isolated/bastion/deploy-cluster.sh ${AZURE_REGION}"
log_info ""
log_info "Note: deploy-cluster.sh automatically runs mirroring if needed (2-4 hours first time)"
log_info ""
log_info "Connection details saved to: ${OUTPUTS_FILE}"
log_info "To use these variables: source ${OUTPUTS_FILE}"
log_info ""

