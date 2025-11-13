# Deployment Fixes for OpenShift CoCo Pattern

## Problem Identified

The previous deployment failed with:
- **Master VMs**: Failed with `OSProvisioningTimedOut` error
- **Root Cause**: VMs couldn't access Azure Blob Storage to download ignition configs
- **NSG Issue**: Cluster API-created NSG (`coco-chg7n-nsg`) had NO security rules
- **NSG Fix Script**: Timed out and failed because:
  1. Azure CLI was not installed on the bastion
  2. Timeout was too short (10 minutes)
  3. PATH wasn't set correctly for script execution

## Fixes Applied

### 1. Azure CLI Installation (cloud-init.yaml)
- Added Microsoft Azure CLI repository to `yum_repos`
- Added `azure-cli` to packages list
- Now Azure CLI will be installed during bastion first boot

### 2. NSG Fix Script Improvements (fix-cluster-nsg.sh)
- **Timeout increased**: 10 minutes → 30 minutes for cluster RG creation
- **PATH handling**: Explicitly set PATH to include `/usr/bin` for Azure CLI
- **Azure CLI verification**: Added check to ensure `az` command is available
- **Better logging**: Added progress updates every 60 seconds
- **Error messages improved**: Show timeout duration in error messages

### 3. Expected Behavior

**Deployment Flow:**
1. Terraform provisions bastion with data disk
2. Cloud-init runs:
   - Installs Azure CLI, git, jq, podman, etc.
   - Formats and mounts 500GB data disk
   - Downloads OpenShift tools
   - Sets up Git HTTP server systemd service
3. configure-bastion.sh runs:
   - Sets Azure credentials in .envrc
   - Clones pattern repository
   - Creates bare Git repo for HTTP serving
   - Starts Git HTTP server
4. wrapper-disconnected.sh runs:
   - Generates install-config.yaml
   - Starts **fix-cluster-nsg.sh** in background
   - Runs `openshift-install create cluster`
5. fix-cluster-nsg.sh (background):
   - Waits up to 30 minutes for Cluster API to create resource group
   - Waits up to 10 minutes for NSG to be created
   - Copies all rules from `nsg-openshift-p54kj` to cluster NSG
   - Enables Storage service endpoint access
6. OpenShift VMs:
   - Now can access Azure Blob Storage via service endpoints
   - Download ignition configs successfully
   - Bootstrap and master nodes provision correctly

## Files Changed

1. `rhdp-isolated/terraform/cloud-init.yaml`
   - Added Azure CLI yum repository
   - Added `azure-cli` to packages

2. `rhdp-isolated/bastion/fix-cluster-nsg.sh`
   - Increased cluster RG timeout: 600s → 1800s (30 min)
   - Added PATH="/usr/bin:..." export
   - Added Azure CLI availability check
   - Added progress logging every 60s
   - Improved error messages

## Next Steps

1. Destroy current failed cluster (`coco-chg7n-rg`)
2. Destroy and recreate bastion infrastructure
3. Run full deployment with fixes
4. Monitor NSG fix script progress via `nsg-fix.log`
5. Verify cluster deploys successfully
6. Verify pattern installation completes

## Testing NSG Fix

To verify the NSG fix worked:
```bash
# On bastion after deployment starts
tail -f ~/coco-pattern/nsg-fix.log

# Check cluster NSG rules (from local machine)
az network nsg rule list -g coco-XXXXX-rg --nsg-name coco-XXXXX-nsg -o table
```

Expected rules in cluster NSG:
- `AllowStorageOutbound` (priority 1000): Allow HTTPS to Azure Storage
- `AllowVNetOutbound` (priority 1001): Allow all traffic within VNet
- `DenyInternetOutbound` (priority 4096): Deny internet access

