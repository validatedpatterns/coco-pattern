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
log_info "Verifying bastion host configuration"
log_info "=========================================="
log_info "Note: Cloud-init does EVERYTHING automatically!"
log_info ""
log_info "What cloud-init configured (from Terraform variables):"
log_info "  ✓ Azure credentials (~/.azure/osServicePrincipal.json)"
log_info "  ✓ Environment variables (~/.envrc with registry, Azure auth)"
log_info "  ✓ SSH key pair (~/.ssh/id_rsa)"
log_info "  ✓ Pattern repository (~/coco-pattern from git)"
log_info "  ✓ Container registry (podman on port 5000)"
log_info "  ✓ Git HTTP server (populated and running)"
log_info "  ✓ Ignition HTTP server (running)"
log_info ""
log_info "This script only verifies the setup is complete"
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

# Wait for cloud-init to complete (using sudo to avoid permission issues)
log_info "Waiting for cloud-init to complete..."
MAX_WAIT=600  # 10 minutes
ELAPSED=0
WAIT_INTERVAL=15

while [ $ELAPSED -lt $MAX_WAIT ]; do
    # Use sudo to avoid permission denied errors
    STATUS=$(ssh -o ConnectTimeout=10 "${BASTION_USER}@${BASTION_IP}" "sudo cloud-init status" 2>/dev/null || echo "waiting")
    
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
    log_warn "Proceeding anyway, but verification will check if setup is complete"
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

# Verify cloud-init completed all setup
log_info "Verifying cloud-init completed full bastion setup..."
ssh "${BASTION_USER}@${BASTION_IP}" bash <<'EOFVERIFY'
#!/bin/bash
set -e

echo ""
echo "Verification Checklist:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Azure credentials
if [ -f ~/.azure/osServicePrincipal.json ]; then
    echo "  ✅ Azure credentials configured"
else
    echo "  ❌ Azure credentials missing (cloud-init failed?)"
    exit 1
fi

# 2. Environment variables
if [ -f ~/.envrc ]; then
    source ~/.envrc
    if [ -n "$REGISTRY_URL" ] && [ -n "$GUID" ]; then
        echo "  ✅ Environment variables configured"
        echo "     GUID: $GUID"
        echo "     Registry: $REGISTRY_URL"
    else
        echo "  ❌ Environment variables incomplete"
        echo "     Expected: REGISTRY_URL and GUID"
        echo "     Found: REGISTRY_URL=${REGISTRY_URL:-unset}, GUID=${GUID:-unset}"
        exit 1
    fi
else
    echo "  ❌ .envrc missing (cloud-init failed?)"
    exit 1
fi

# 3. SSH key
if [ -f ~/.ssh/id_rsa ]; then
    echo "  ✅ SSH key generated"
else
    echo "  ❌ SSH key missing (cloud-init failed?)"
    exit 1
fi

# 4. Pattern repository
if [ -d ~/coco-pattern ]; then
    cd ~/coco-pattern
    BRANCH=$(git branch --show-current)
    echo "  ✅ Pattern repository cloned (branch: $BRANCH)"
else
    echo "  ❌ Pattern repository missing (cloud-init failed?)"
    exit 1
fi

# 5. Git HTTP server
if systemctl is-active --quiet git-http.service; then
    echo "  ✅ Git HTTP Server: Running (port 8080)"
    if curl -sf http://localhost:8080/coco-pattern/.git/HEAD > /dev/null; then
        echo "     → Serving pattern repository"
    else
        echo "     ⚠️ Server running but content not accessible"
    fi
else
    echo "  ❌ Git HTTP Server: Not running"
    exit 1
fi

# 6. Container registry
if systemctl is-active --quiet registry.service; then
    echo "  ✅ Container Registry: Running (port 5000)"
    if curl -sf http://localhost:5000/v2/ > /dev/null; then
        echo "     → Accessible at http://10.0.1.4:5000"
    else
        echo "     ⚠️ Service running but not responding"
    fi
else
    echo "  ❌ Container Registry: Not running"
    exit 1
fi

# 7. Ignition HTTP server
if systemctl is-active --quiet ignition-http.service; then
    echo "  ✅ Ignition HTTP Server: Running (port 8081)"
else
    echo "  ❌ Ignition HTTP Server: Not running"
    exit 1
fi

echo ""
echo "✅ ALL CLOUD-INIT SETUP VERIFIED - Bastion is fully configured!"

EOFVERIFY

# Get bastion private IP for git server
BASTION_PRIVATE_IP=$(ssh "${BASTION_USER}@${BASTION_IP}" "hostname -I | awk '{print \$1}'")

log_info ""
log_info "=========================================="
log_info "✅ Bastion verification complete!"
log_info "=========================================="
log_info ""
log_info "Cloud-init configured EVERYTHING automatically:"
log_info "  ✓ System packages and OpenShift tools"
log_info "  ✓ Data disk mounted (500GB)"
log_info "  ✓ Azure credentials"
log_info "  ✓ Environment variables (with ACR)"
log_info "  ✓ SSH key pair"
log_info "  ✓ Pattern repository (from Terraform git_remote_url/git_branch)"
log_info "  ✓ Git HTTP server (running on port 8080)"
log_info "  ✓ Ignition HTTP server (running on port 8081)"
log_info ""
log_info "Services:"
log_info "  • Container Registry: http://${BASTION_PRIVATE_IP}:5000"
log_info "  • Git HTTP: http://${BASTION_PRIVATE_IP}:8080/coco-pattern"
log_info "  • Ignition HTTP: http://${BASTION_PRIVATE_IP}:8081/"
log_info ""
log_info "Next steps:"
log_info "  1. Copy pull secret to bastion:"
log_info "     scp ~/pull-secret.json ${BASTION_USER}@${BASTION_IP}:~/"
log_info ""
log_info "  2. SSH to bastion and deploy:"
log_info "     ssh ${BASTION_USER}@${BASTION_IP}"
log_info "     cd ~/coco-pattern"
log_info "     ./rhdp-isolated/bastion/deploy-cluster.sh eastasia"
log_info ""
log_info "Note: deploy-cluster.sh automatically runs mirroring if needed (2-4 hrs first time)"
log_info "All configuration is automated - no manual setup required!"
log_info ""
