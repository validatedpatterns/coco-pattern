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

# Create terraform.tfvars
log_info "Creating terraform.tfvars from environment variables"
cat > "${TERRAFORM_DIR}/terraform.tfvars" <<EOF
region              = "${AZURE_REGION}"
resource_group_name = "${RESOURCEGROUP}"
guid                = "${GUID}"

# Generated from environment
tags = {
  pattern    = "coco-disconnected"
  managed_by = "terraform"
  guid       = "${GUID}"
}
EOF

log_info "terraform.tfvars created"

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
ACR_LOGIN_SERVER=$(terraform output -raw acr_login_server)
ACR_NAME=$(terraform output -raw acr_name)

# Save outputs to file for later use
OUTPUTS_FILE="${SCRIPT_DIR}/infrastructure-outputs.env"
log_info "Saving outputs to ${OUTPUTS_FILE}"

cat > "${OUTPUTS_FILE}" <<EOF
# Infrastructure outputs from Terraform
# Source this file to use these variables

export BASTION_IP="${BASTION_IP}"
export BASTION_USER="${BASTION_USER}"
export ACR_LOGIN_SERVER="${ACR_LOGIN_SERVER}"
export ACR_NAME="${ACR_NAME}"
export AZURE_REGION="${AZURE_REGION}"
export GUID="${GUID}"
export RESOURCEGROUP="${RESOURCEGROUP}"
export CLIENT_ID="${CLIENT_ID}"
export PASSWORD="${PASSWORD}"
export TENANT="${TENANT}"
export SUBSCRIPTION="${SUBSCRIPTION}"

# Get ACR credentials (these are sensitive)
export ACR_USERNAME=$(terraform output -raw acr_admin_username)
export ACR_PASSWORD=$(terraform output -raw acr_admin_password)
EOF

chmod 600 "${OUTPUTS_FILE}"

log_info ""
log_info "=========================================="
log_info "Infrastructure provisioning complete!"
log_info "=========================================="
log_info ""
log_info "Bastion Host: ${BASTION_USER}@${BASTION_IP}"
log_info "ACR: ${ACR_LOGIN_SERVER}"
log_info ""
log_info "Next steps:"
log_info "1. Configure the bastion host:"
log_info "   ./configure-bastion.sh"
log_info ""
log_info "2. SSH to bastion (credentials saved in ${OUTPUTS_FILE}):"
log_info "   ssh ${BASTION_USER}@${BASTION_IP}"
log_info ""
log_info "Connection details saved to: ${OUTPUTS_FILE}"
log_info "To use these variables: source ${OUTPUTS_FILE}"
log_info ""

