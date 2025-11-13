# Deprecated Scripts - Moved 2025-11-13

This directory contains scripts and Terraform modules that were deprecated as part of the refactoring to a **Terraform-first architecture**.

## Why These Were Deprecated

The original implementation used shell scripts to perform infrastructure operations (downloading VHDs, uploading to Azure Storage, creating managed images, deploying ignition configs). This approach had several issues:

1. **Imperative vs Declarative**: Shell scripts are imperative and harder to maintain
2. **State Management**: No built-in state tracking (unlike Terraform)
3. **Idempotency**: Scripts require complex logic to be idempotent
4. **Error Recovery**: Difficult to resume from failures
5. **Code Duplication**: Logic spread across multiple wrapper scripts

## What Was Moved

### Deprecated Wrapper Scripts

#### `wrapper-upi-complete.sh` (463 lines)
- **Purpose**: Full UPI deployment orchestration with shell-based infrastructure
- **Issues**: 
  - Downloaded and uploaded RHCOS VHD using `az` CLI commands
  - Created storage accounts, containers, and blobs imperatively
  - Managed ignition deployment with `cp` and `scp` commands
  - Complex error handling and retry logic
- **Replaced by**: `deploy-cluster.sh` (247 lines) + Terraform modules

#### `wrapper-upi.sh` (296 lines)
- **Purpose**: Initial UPI attempt without DNS/LB infrastructure
- **Issues**: 
  - Incomplete infrastructure (no load balancers, no DNS)
  - VMs deployed but couldn't form a cluster
  - Still used Azure Storage for ignition (not truly disconnected)
- **Replaced by**: `terraform-upi-complete/` module

#### `wrapper-disconnected.sh` (284 lines)
- **Purpose**: IPI-based disconnected deployment
- **Issues**:
  - Relied on dynamic NSG fixes (race conditions)
  - Used Cluster API which overrides pre-configured NSG rules
  - Required `fix-cluster-nsg.sh` hack
  - Not truly disconnected (needed Azure Storage)
- **Replaced by**: UPI approach with bastion-served ignition

### Deprecated Helper Scripts

#### `fix-cluster-nsg.sh`
- **Purpose**: Dynamically copy NSG rules to CAPI-generated NSG
- **Issues**:
  - Race condition with CAPI resource creation
  - Flaky - sometimes timed out before CAPI created resources
  - Hack to work around CAPI's declarative reconciliation
- **Replaced by**: Proper subnet-level NSG in base Terraform module

### Deprecated Terraform Module

#### `terraform-upi/`
- **Purpose**: Initial UPI Terraform attempt
- **Issues**:
  - Incomplete - only deployed VMs, no DNS or load balancers
  - Required separate shell scripts for RHCOS image prep
  - Didn't handle ignition deployment
- **Replaced by**: `terraform-upi-complete/` (comprehensive UPI module)

## New Architecture (Terraform-First)

### Active Components

```
rhdp-isolated/
├── bastion/
│   ├── deploy-cluster.sh          # NEW: Minimal orchestration (247 lines)
│   ├── mirror.sh                  # Image mirroring (still needed)
│   ├── rhdp-cluster-define-disconnected.py  # Install-config generator
│   ├── install-config.yaml.j2     # Template
│   └── imageset-config.yaml       # oc-mirror config
├── terraform/                     # Base infrastructure (VNet, bastion, NSG)
├── terraform-rhcos-image/         # NEW: RHCOS image preparation (Terraform)
└── terraform-upi-complete/        # NEW: Complete UPI with DNS, LBs, VMs
    └── ignition-deploy.tf         # NEW: Ignition deployment (Terraform)
```

### Key Improvements

1. **RHCOS Image Preparation**: Now Terraform module (`terraform-rhcos-image/`)
   - Declarative VHD download, upload, and image creation
   - Idempotent and state-tracked
   - ~100 lines of Terraform vs 150 lines of bash

2. **Ignition Deployment**: Now Terraform resource (`ignition-deploy.tf`)
   - Uses `null_resource` with provisioners
   - Triggered by ignition file changes
   - Verifies HTTP server accessibility

3. **Minimal Orchestration**: `deploy-cluster.sh` (247 lines vs 463 lines)
   - Only orchestrates OpenShift operations (not infrastructure)
   - Calls Terraform modules for infrastructure
   - Clear separation of concerns

4. **True Idempotency**: Terraform state management
   - Can safely re-run deployments
   - Detects and applies only required changes
   - Easy rollback and destroy

## Migration Guide

If you were using the old scripts:

### Old Approach
```bash
# OLD: wrapper-upi-complete.sh did everything
./rhdp-isolated/bastion/wrapper-upi-complete.sh eastasia
```

### New Approach
```bash
# NEW: Terraform prepares RHCOS image
cd rhdp-isolated/terraform-rhcos-image
terraform init
terraform apply

# NEW: Minimal script orchestrates OpenShift ops
cd ../bastion
./deploy-cluster.sh eastasia
```

## Line Count Comparison

| Component | Old (Shell) | New (Terraform + Shell) | Reduction |
|-----------|-------------|-------------------------|-----------|
| RHCOS Image | 150 lines bash | 100 lines Terraform | -33% |
| Ignition Deploy | 50 lines bash | 70 lines Terraform | More robust |
| Orchestration | 463 lines bash | 247 lines bash | -47% |
| **Total** | **663 lines** | **417 lines** | **-37%** |

Plus: Terraform state management, idempotency, and declarative infrastructure!

## Why Keep These Files?

These scripts represent:
- Historical approaches and lessons learned
- Alternative implementations for reference
- Troubleshooting examples
- Documentation of what NOT to do

## Recovery

If you need to restore any of these scripts:

```bash
# Copy back to active location
cp deprecated-scripts-20251113/wrapper-upi-complete.sh ../bastion/
```

However, it's **strongly recommended** to use the new Terraform-first approach.

---

**Deprecated**: 2025-11-13  
**Reason**: Refactored to Terraform-first architecture for better maintainability  
**Replaced by**: `deploy-cluster.sh` + Terraform modules

