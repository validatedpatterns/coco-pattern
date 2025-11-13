#!/bin/bash
# Fix Cluster API NSG by copying rules from our pre-configured NSG

set -e

log_info() {
    echo -e "\033[0;32m[INFO]\033[0m $1"
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1"
}

# Ensure Azure CLI is in PATH
export PATH="/usr/bin:/usr/local/bin:/var/cache/oc-mirror/bin:${PATH}"

# Source environment variables
if [ -f ~/.envrc ]; then
    source ~/.envrc
fi

# Verify Azure CLI is available
if ! command -v az &> /dev/null; then
    log_error "Azure CLI (az) not found in PATH"
    exit 1
fi

# Configuration
SOURCE_NSG="nsg-openshift-${GUID}"
SOURCE_RG="${RESOURCEGROUP}"
CLUSTER_NAME="coco"

log_info "Waiting for Cluster API to create NSG..."
log_info "Will copy rules from: ${SOURCE_NSG} in ${SOURCE_RG}"
log_info "Azure CLI version: $(az version --query 'azure-cli' -o tsv 2>/dev/null || echo 'installed')"

# Wait for cluster resource group to be created (max 30 minutes - increased from 10)
TIMEOUT=1800
ELAPSED=0
CLUSTER_RG=""

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Find cluster resource group
    CLUSTER_RG=$(az group list --query "[?contains(name, '${CLUSTER_NAME}-')].name" -o tsv 2>/dev/null | head -1)
    
    if [ -n "$CLUSTER_RG" ]; then
        log_info "Found cluster resource group: ${CLUSTER_RG}"
        break
    fi
    
    if [ $((ELAPSED % 60)) -eq 0 ]; then
        log_info "Still waiting for cluster RG... (${ELAPSED}s / ${TIMEOUT}s)"
    fi
    
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ -z "$CLUSTER_RG" ]; then
    log_error "Cluster resource group not created within timeout (${TIMEOUT}s)"
    exit 1
fi

# Wait for NSG to be created in cluster resource group (max 10 minutes)
log_info "Waiting for NSG to be created in ${CLUSTER_RG}..."
TIMEOUT=600
ELAPSED=0
CLUSTER_NSG=""

while [ $ELAPSED -lt $TIMEOUT ]; do
    CLUSTER_NSG=$(az network nsg list -g "$CLUSTER_RG" --query "[0].name" -o tsv 2>/dev/null)
    
    if [ -n "$CLUSTER_NSG" ]; then
        log_info "Found cluster NSG: ${CLUSTER_NSG}"
        break
    fi
    
    if [ $((ELAPSED % 60)) -eq 0 ]; then
        log_info "Still waiting for NSG in ${CLUSTER_RG}... (${ELAPSED}s / ${TIMEOUT}s)"
    fi
    
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ -z "$CLUSTER_NSG" ]; then
    log_error "Cluster NSG not created within timeout (${TIMEOUT}s)"
    exit 1
fi

# Copy NSG rules from source to cluster NSG
log_info "Copying NSG rules from ${SOURCE_NSG} to ${CLUSTER_NSG}..."

# Get rules from source NSG
RULES=$(az network nsg rule list -g "$SOURCE_RG" --nsg-name "$SOURCE_NSG" --query "[].{name:name, priority:priority, direction:direction, access:access, protocol:protocol, sourcePortRange:sourcePortRange, destinationPortRange:destinationPortRange, sourceAddressPrefix:sourceAddressPrefix, destinationAddressPrefix:destinationAddressPrefix, description:description}" -o json)

if [ -z "$RULES" ] || [ "$RULES" = "[]" ]; then
    log_error "No rules found in source NSG"
    exit 1
fi

log_info "Found $(echo $RULES | jq '. | length') rules to copy"

# Copy each rule - save to temp file to preserve exit codes
TEMP_RULES="/tmp/nsg-rules-$$.txt"
echo "$RULES" | jq -c '.[]' > "$TEMP_RULES"

FAILED_RULES=0
CREATED_RULES=0

while read -r rule; do
    NAME=$(echo "$rule" | jq -r '.name')
    PRIORITY=$(echo "$rule" | jq -r '.priority')
    DIRECTION=$(echo "$rule" | jq -r '.direction')
    ACCESS=$(echo "$rule" | jq -r '.access')
    PROTOCOL=$(echo "$rule" | jq -r '.protocol')
    SRC_PORT=$(echo "$rule" | jq -r '.sourcePortRange')
    DST_PORT=$(echo "$rule" | jq -r '.destinationPortRange')
    SRC_ADDR=$(echo "$rule" | jq -r '.sourceAddressPrefix')
    DST_ADDR=$(echo "$rule" | jq -r '.destinationAddressPrefix')
    DESC=$(echo "$rule" | jq -r '.description // empty')
    
    log_info "Creating rule: ${NAME} (priority: $PRIORITY, direction: $DIRECTION)"
    
    # Check if rule already exists and delete it first
    if az network nsg rule show -g "$CLUSTER_RG" --nsg-name "$CLUSTER_NSG" -n "$NAME" &>/dev/null; then
        log_info "Rule ${NAME} already exists, deleting..."
        az network nsg rule delete -g "$CLUSTER_RG" --nsg-name "$CLUSTER_NSG" -n "$NAME" &>/dev/null
    fi
    
    # Create the rule
    if az network nsg rule create \
        -g "$CLUSTER_RG" \
        --nsg-name "$CLUSTER_NSG" \
        -n "$NAME" \
        --priority $PRIORITY \
        --direction $DIRECTION \
        --access $ACCESS \
        --protocol $PROTOCOL \
        --source-port-ranges "$SRC_PORT" \
        --destination-port-ranges "$DST_PORT" \
        --source-address-prefixes "$SRC_ADDR" \
        --destination-address-prefixes "$DST_ADDR" \
        --description "$DESC" \
        &>/dev/null; then
        log_info "✅ Created rule: ${NAME}"
        CREATED_RULES=$((CREATED_RULES + 1))
    else
        log_error "❌ Failed to create rule: ${NAME}"
        FAILED_RULES=$((FAILED_RULES + 1))
    fi
done < "$TEMP_RULES"

rm -f "$TEMP_RULES"

if [ $FAILED_RULES -gt 0 ]; then
    log_error "Failed to create $FAILED_RULES out of $(echo "$RULES" | jq '. | length') rules"
    exit 1
fi

log_info "✅ NSG rules copied successfully"
log_info ""
log_info "Cluster NSG ${CLUSTER_NSG} now has the following rules:"
az network nsg rule list -g "$CLUSTER_RG" --nsg-name "$CLUSTER_NSG" --query "[].{Name:name, Priority:priority, Direction:direction, Access:access}" -o table

