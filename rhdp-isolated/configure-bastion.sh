#!/usr/bin/env bash
# Configure the bastion host with environment variables and pattern repository
# Note: Most setup is now done via cloud-init in Terraform
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUTS_FILE="${SCRIPT_DIR}/infrastructure-outputs.env"

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

# Check if outputs file exists
if [ ! -f "${OUTPUTS_FILE}" ]; then
    log_error "Infrastructure outputs file not found: ${OUTPUTS_FILE}"
    log_error "Please run ./provision.sh first"
    exit 1
fi

# Source the outputs
source "${OUTPUTS_FILE}"

log_info "=========================================="
log_info "Configuring bastion host"
log_info "=========================================="
log_info "Note: Hardware and software setup via cloud-init"
log_info "This script handles:"
log_info "  - Environment variables"
log_info "  - Azure credentials"
log_info "  - Pattern repository upload"
log_info "=========================================="

log_info "Bastion: ${BASTION_USER}@${BASTION_IP}"

# Check SSH connectivity
log_info "Testing SSH connectivity..."
if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "${BASTION_USER}@${BASTION_IP}" "echo 'SSH connection successful'" > /dev/null 2>&1; then
    log_error "Cannot connect to bastion host via SSH"
    log_error "Please check that the VM is running and cloud-init has completed"
    log_error "You can check cloud-init status with: ssh ${BASTION_USER}@${BASTION_IP} 'cloud-init status'"
    exit 1
fi

log_info "SSH connection successful"

# Wait for cloud-init to complete
log_info "Waiting for cloud-init to complete..."
MAX_WAIT=600  # 10 minutes
ELAPSED=0
WAIT_INTERVAL=15

while [ $ELAPSED -lt $MAX_WAIT ]; do
    STATUS=$(ssh -o ConnectTimeout=10 "${BASTION_USER}@${BASTION_IP}" "cloud-init status" 2>/dev/null || echo "waiting")
    
    if echo "$STATUS" | grep -q "status: done"; then
        log_info "Cloud-init completed successfully"
        break
    elif echo "$STATUS" | grep -q "status: error"; then
        log_error "Cloud-init encountered an error"
        log_error "Fetching cloud-init logs..."
        ssh "${BASTION_USER}@${BASTION_IP}" "sudo cat /var/log/cloud-init.log | tail -100"
        exit 1
    elif echo "$STATUS" | grep -q "status: running"; then
        log_info "Cloud-init is still running... (${ELAPSED}s elapsed)"
    else
        log_info "Cloud-init status: initializing... (${ELAPSED}s elapsed)"
    fi
    
    sleep $WAIT_INTERVAL
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    log_warn "Timed out waiting for cloud-init (${MAX_WAIT}s)"
    log_warn "Proceeding anyway, but some tools may not be available yet"
    log_warn "You can check status later with: ssh ${BASTION_USER}@${BASTION_IP} 'cloud-init status'"
fi

# Verify cloud-init installed tools
log_info "Verifying cloud-init installed tools..."
ssh "${BASTION_USER}@${BASTION_IP}" bash <<'EOFVERIFY'
#!/bin/bash
echo "Checking installed tools..."

MISSING=""

# Check for required tools
for tool in oc kubectl openshift-install oc-mirror git podman python3; do
    if ! command -v $tool &> /dev/null; then
        echo "  [MISSING] $tool"
        MISSING="$MISSING $tool"
    else
        VERSION=$($tool version 2>&1 | head -n1 || echo "installed")
        echo "  [OK] $tool: $VERSION"
    fi
done

# Check data disk
if mountpoint -q /var/cache/oc-mirror; then
    echo "  [OK] Data disk mounted at /var/cache/oc-mirror"
    df -h /var/cache/oc-mirror
else
    echo "  [WARN] Data disk not mounted at /var/cache/oc-mirror"
fi

if [ -n "$MISSING" ]; then
    echo ""
    echo "WARNING: Some tools are missing:$MISSING"
    echo "Cloud-init may still be running. Check: cloud-init status"
    exit 1
fi

echo ""
echo "All required tools are available!"
EOFVERIFY

if [ $? -ne 0 ]; then
    log_warn "Some tools are not yet available"
    log_warn "This is normal if cloud-init is still completing"
    log_warn "Wait a few minutes and check: ssh ${BASTION_USER}@${BASTION_IP} 'cloud-init status'"
fi

# Create Azure credentials directory on bastion
log_info "Configuring Azure credentials on bastion..."
ssh "${BASTION_USER}@${BASTION_IP}" "mkdir -p ~/.azure"

# Create service principal JSON
AZURE_CREDS=$(cat <<EOF
{
  "subscriptionId": "${SUBSCRIPTION}",
  "clientId": "${CLIENT_ID}",
  "clientSecret": "${PASSWORD}",
  "tenantId": "${TENANT}"
}
EOF
)

echo "$AZURE_CREDS" | ssh "${BASTION_USER}@${BASTION_IP}" "cat > ~/.azure/osServicePrincipal.json && chmod 600 ~/.azure/osServicePrincipal.json"

# Create environment file on bastion
log_info "Creating environment file on bastion..."
BASTION_ENV=$(cat <<EOF
# Azure and RHDP Environment Variables
export GUID="${GUID}"
export CLIENT_ID="${CLIENT_ID}"
export PASSWORD="${PASSWORD}"
export TENANT="${TENANT}"
export SUBSCRIPTION="${SUBSCRIPTION}"
export RESOURCEGROUP="${RESOURCEGROUP}"
export AZURE_REGION="${AZURE_REGION}"

# ACR Credentials
export ACR_LOGIN_SERVER="${ACR_LOGIN_SERVER}"
export ACR_NAME="${ACR_NAME}"
export ACR_USERNAME="${ACR_USERNAME}"
export ACR_PASSWORD="${ACR_PASSWORD}"

# Ensure local bin is in PATH
export PATH="\${HOME}/.local/bin:\${PATH}"
EOF
)

echo "$BASTION_ENV" | ssh "${BASTION_USER}@${BASTION_IP}" "cat > ~/.envrc && chmod 600 ~/.envrc"

# Add to bashrc if not already there
ssh "${BASTION_USER}@${BASTION_IP}" "if ! grep -q 'source ~/.envrc' ~/.bashrc; then echo 'source ~/.envrc' >> ~/.bashrc; fi"

# Clone pattern repository to bastion
log_info "Cloning pattern repository to bastion..."
PATTERN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PATTERN_ROOT}"

# Detect current git remote and branch
GIT_REMOTE=$(git config --get remote.origin.url || echo "")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD || echo "main")

if [ -z "$GIT_REMOTE" ]; then
    log_error "Could not determine git remote URL"
    log_error "Please ensure you are in a git repository with a remote configured"
    exit 1
fi

# Convert SSH URL to HTTPS URL if needed (for bastion access without SSH keys)
if [[ "$GIT_REMOTE" =~ ^git@ ]]; then
    log_info "Converting SSH URL to HTTPS for bastion access..."
    # Convert git@github.com:user/repo.git -> https://github.com/user/repo.git
    GIT_REMOTE_HTTPS=$(echo "$GIT_REMOTE" | sed -E 's|^git@([^:]+):(.+)$|https://\1/\2|')
    log_info "Original (SSH): ${GIT_REMOTE}"
    log_info "Converted (HTTPS): ${GIT_REMOTE_HTTPS}"
    GIT_REMOTE="$GIT_REMOTE_HTTPS"
else
    log_info "Git remote: ${GIT_REMOTE}"
fi

log_info "Git branch: ${GIT_BRANCH}"

# Clone the repository on the bastion
log_info "Cloning ${GIT_REMOTE} (branch: ${GIT_BRANCH}) to bastion..."
ssh "${BASTION_USER}@${BASTION_IP}" bash <<EOFCLONE
set -e

# Remove existing directory if present
if [ -d ~/coco-pattern ]; then
    echo "[INFO] Removing existing coco-pattern directory"
    rm -rf ~/coco-pattern
fi

# Clone the repository
echo "[INFO] Cloning repository..."
git clone --branch ${GIT_BRANCH} ${GIT_REMOTE} ~/coco-pattern

cd ~/coco-pattern
echo "[INFO] Cloned to: \$(pwd)"
echo "[INFO] Current branch: \$(git branch --show-current)"
echo "[INFO] Latest commit: \$(git log -1 --oneline)"

EOFCLONE

if [ $? -eq 0 ]; then
    log_info "Repository cloned successfully"
else
    log_error "Failed to clone repository"
    log_error "Please check git credentials and network connectivity from bastion"
    exit 1
fi

log_info ""
log_info "=========================================="
log_info "Bastion configuration complete!"
log_info "=========================================="
log_info ""
log_info "To connect to bastion:"
log_info "  ssh ${BASTION_USER}@${BASTION_IP}"
log_info ""
log_info "Cloud-init handled:"
log_info "  ✓ System packages and updates"
log_info "  ✓ OpenShift CLI tools (oc, kubectl, openshift-install, oc-mirror)"
log_info "  ✓ Container tools (podman, skopeo)"
log_info "  ✓ Python packages (jinja2, typer, rich, PyYAML, ansible)"
log_info "  ✓ Data disk setup and mount"
log_info ""
log_info "This script configured:"
log_info "  ✓ Azure credentials"
log_info "  ✓ Environment variables"
log_info "  ✓ Pattern repository (cloned from ${GIT_REMOTE}, branch ${GIT_BRANCH})"
log_info ""
log_info "Next steps (on bastion):"
log_info "  1. cd ~/coco-pattern"
log_info "  2. Ensure pull secret: ~/pull-secret.json"
log_info "  3. Run mirroring: ./rhdp-isolated/bastion/mirror.sh"
log_info "  4. Install cluster: ./rhdp-isolated/bastion/wrapper-disconnected.sh ${AZURE_REGION}"
log_info ""
log_info "Note: You need to copy your pull-secret.json to the bastion:"
log_info "  scp ~/pull-secret.json ${BASTION_USER}@${BASTION_IP}:~/"
log_info ""
log_info "Git repository info:"
log_info "  Remote: ${GIT_REMOTE}"
log_info "  Branch: ${GIT_BRANCH}"
log_info ""
log_info "To check cloud-init completion status:"
log_info "  ssh ${BASTION_USER}@${BASTION_IP} 'cloud-init status --long'"
log_info ""
