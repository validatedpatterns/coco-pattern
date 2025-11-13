#!/usr/bin/env bash
# Stage 2: Mirror images from bastion to ACR
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

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info "=========================================="
log_info "CoCo Pattern Image Mirroring to ACR"
log_info "=========================================="

# Load environment
if [ -f ~/.envrc ]; then
    source ~/.envrc
else
    log_error "Environment file ~/.envrc not found"
    log_error "Please ensure configure-bastion.sh was run successfully"
    exit 1
fi

# Set registry URL (defaults to bastion-hosted registry)
REGISTRY_URL="${REGISTRY_URL:-localhost:5000}"

log_info "Container registry: ${REGISTRY_URL}"

# No authentication required for bastion-hosted registry (localhost)

# Verify pull secret exists
PULL_SECRET="${HOME}/pull-secret.json"
if [ ! -f "${PULL_SECRET}" ]; then
    log_error "Pull secret not found at ${PULL_SECRET}"
    log_error "Please copy your pull secret to the bastion:"
    log_error "  scp ~/pull-secret.json ${USER}@<bastion-ip>:~/"
    exit 1
fi

log_info "All prerequisites verified"

# Setup workspace
MIRROR_WORKSPACE="/var/cache/oc-mirror/workspace"
CLUSTER_RESOURCES_DIR="${MIRROR_WORKSPACE}/working-dir/cluster-resources"

log_step "Setting up mirror workspace at ${MIRROR_WORKSPACE}"
mkdir -p "${MIRROR_WORKSPACE}"

# Copy imageset config to workspace
cp "${SCRIPT_DIR}/imageset-config.yaml" "${MIRROR_WORKSPACE}/"

# Verify oc-mirror is available
if ! command -v oc-mirror &> /dev/null; then
    log_error "oc-mirror not found in PATH"
    log_error "Please ensure configure-bastion.sh was run successfully"
    exit 1
fi

# Note: We use oc-mirror --v2 (the version command without --v2 shows deprecation warning)
log_info "oc-mirror found (using v2 mode)"

# Create merged auth file in XDG_RUNTIME_DIR for oc-mirror v2
log_step "Setting up authentication for oc-mirror v2"

# oc-mirror v2 expects auth in standard locations: ${XDG_RUNTIME_DIR}/containers/auth.json
# Create the directory structure
AUTH_DIR="${HOME}/.docker"
mkdir -p "${AUTH_DIR}"
MERGED_AUTH_FILE="${AUTH_DIR}/config.json"

# Start with the Red Hat pull secret
cp "${PULL_SECRET}" "${MERGED_AUTH_FILE}"

# Verify bastion container registry is accessible
log_step "Verifying bastion container registry: ${REGISTRY_URL}"

if curl -sf "http://${REGISTRY_URL}/v2/" > /dev/null 2>&1; then
    log_info "Bastion registry is accessible"
else
    log_error "Cannot access bastion registry at ${REGISTRY_URL}"
    log_error "Please ensure registry.service is running: systemctl status registry.service"
    exit 1
fi

# Verify Red Hat registry access
log_step "Verifying Red Hat registry access with pull secret"
if ! podman login registry.redhat.io --authfile="${MERGED_AUTH_FILE}" --get-login &>/dev/null; then
    log_warn "Could not verify registry.redhat.io access"
    log_warn "Continuing anyway, oc-mirror will use the pull secret"
fi

log_info "Authentication configured at: ${MERGED_AUTH_FILE}"

# Display disk space
log_info "Available disk space:"
df -h "${MIRROR_WORKSPACE}"

# Warn user about time
log_warn "=========================================="
log_warn "IMPORTANT: This process will take 2-4 hours"
log_warn "It will download and mirror:"
log_warn "  - OpenShift 4.20 platform images (~30-40GB)"
log_warn "  - Operator catalogs and images (~20-30GB)"
log_warn "  - Additional CoCo and pattern images (~10GB)"
log_warn "=========================================="
log_info "Starting in 10 seconds... (Ctrl+C to cancel)"
sleep 10

# Run oc-mirror
log_step "Starting oc-mirror operation..."
log_info "Source: Red Hat registries (quay.io, registry.redhat.io)"
log_info "Destination: ${ACR_LOGIN_SERVER}"
log_info "Workspace: ${MIRROR_WORKSPACE}"

# Note: oc-mirror v2 uses standard Docker/Podman auth locations automatically
# We don't set REGISTRY_AUTH_FILE as it causes parsing errors in v2
log_info "oc-mirror will use auth from: ${MERGED_AUTH_FILE}"

# Run oc-mirror with v2 flag
START_TIME=$(date +%s)

log_info "Executing oc-mirror..."
log_info "Command: oc-mirror --config=${MIRROR_WORKSPACE}/imageset-config.yaml --workspace file://${MIRROR_WORKSPACE} docker://${REGISTRY_URL} --v2 --dest-tls-verify=false"

if oc-mirror \
    --config="${MIRROR_WORKSPACE}/imageset-config.yaml" \
    --workspace "file://${MIRROR_WORKSPACE}" \
    "docker://${REGISTRY_URL}" \
    --v2 \
    --dest-tls-verify=false; then
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    HOURS=$((DURATION / 3600))
    MINUTES=$(((DURATION % 3600) / 60))
    
    log_info "=========================================="
    log_info "Mirroring completed successfully!"
    log_info "Duration: ${HOURS}h ${MINUTES}m"
    log_info "=========================================="
else
    log_error "oc-mirror failed!"
    log_error "Check the logs above for details"
    exit 1
fi

# Verify cluster resources were generated
if [ ! -d "${CLUSTER_RESOURCES_DIR}" ]; then
    log_error "Cluster resources directory not found: ${CLUSTER_RESOURCES_DIR}"
    log_error "oc-mirror may not have completed successfully"
    exit 1
fi

log_step "Examining generated cluster resources..."
ls -lh "${CLUSTER_RESOURCES_DIR}"

# Find and display the generated files
IDMS_FILES=$(find "${CLUSTER_RESOURCES_DIR}" -name "idms-*.yaml" 2>/dev/null)
ITMS_FILES=$(find "${CLUSTER_RESOURCES_DIR}" -name "itms-*.yaml" 2>/dev/null)
CS_FILES=$(find "${CLUSTER_RESOURCES_DIR}" -name "cs-*.yaml" 2>/dev/null)

log_info ""
log_info "Generated manifests:"
if [ -n "$IDMS_FILES" ]; then
    log_info "ImageDigestMirrorSet files:"
    echo "$IDMS_FILES" | while read file; do
        log_info "  - $(basename $file)"
    done
else
    log_warn "No IDMS files found"
fi

if [ -n "$ITMS_FILES" ]; then
    log_info "ImageTagMirrorSet files:"
    echo "$ITMS_FILES" | while read file; do
        log_info "  - $(basename $file)"
    done
else
    log_warn "No ITMS files found"
fi

if [ -n "$CS_FILES" ]; then
    log_info "CatalogSource files:"
    echo "$CS_FILES" | while read file; do
        log_info "  - $(basename $file)"
        # Extract catalog source name for reference
        CS_NAME=$(grep "^  name:" "$file" | head -n1 | awk '{print $2}')
        if [ -n "$CS_NAME" ]; then
            log_info "    CatalogSource name: ${CS_NAME}"
        fi
    done
else
    log_warn "No CatalogSource files found"
fi

# Copy cluster resources to a known location for installation
INSTALL_MANIFESTS_DIR="${HOME}/coco-pattern/cluster-resources"
log_step "Copying cluster resources to ${INSTALL_MANIFESTS_DIR}"
mkdir -p "${INSTALL_MANIFESTS_DIR}"
cp -r "${CLUSTER_RESOURCES_DIR}"/* "${INSTALL_MANIFESTS_DIR}/"

log_info "Cluster resources copied to: ${INSTALL_MANIFESTS_DIR}"

# Create a summary file
SUMMARY_FILE="${INSTALL_MANIFESTS_DIR}/mirror-summary.txt"
cat > "${SUMMARY_FILE}" <<EOF
Mirror Operation Summary
========================
Date: $(date)
Duration: ${HOURS}h ${MINUTES}m
Registry: ${REGISTRY_URL} (bastion-hosted)

Generated Resources:
$(ls -1 "${INSTALL_MANIFESTS_DIR}")

CatalogSource Names (use these in values-disconnected.yaml):
EOF

# Extract catalog source names
find "${INSTALL_MANIFESTS_DIR}" -name "cs-*.yaml" -exec grep "^  name:" {} \; | awk '{print "  - "$2}' >> "${SUMMARY_FILE}"

cat >> "${SUMMARY_FILE}" <<EOF

Next Steps:
1. Review generated manifests in: ${INSTALL_MANIFESTS_DIR}
2. Run the disconnected installer:
   ./rhdp-isolated/bastion/wrapper-disconnected.sh <region>

Note: The installer will automatically apply these manifests.
EOF

log_info ""
log_info "=========================================="
log_info "Mirror Summary"
log_info "=========================================="
cat "${SUMMARY_FILE}"
log_info "=========================================="

log_info ""
log_info "Next steps:"
log_info "  1. Review the generated manifests in: ${INSTALL_MANIFESTS_DIR}"
log_info "  2. Install the disconnected cluster:"
log_info "     cd ~/coco-pattern"
log_info "     ./rhdp-isolated/bastion/wrapper-disconnected.sh <region>"
log_info ""
log_info "Mirror operation complete!"

