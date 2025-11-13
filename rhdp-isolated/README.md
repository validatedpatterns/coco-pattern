# Disconnected CoCo Pattern Deployment - Terraform-First Architecture

This directory contains **declarative Terraform modules** and **minimal orchestration scripts** for deploying the CoCo pattern in a **truly disconnected** Azure environment.

## Architecture Overview

```
Developer Workstation (Stage 1)
    |
    | Terraform (Base Infrastructure)
    v
Azure Infrastructure:
  - Bastion Host (serves ignition, git, images)
  - Private VNet for OpenShift (NO internet)
  - Azure Container Registry (ACR) for mirrored images
    |
    | Stage 2 (from Bastion)
    v
  - Mirror images to ACR (oc-mirror)
  - Terraform prepares RHCOS image
  - Terraform deploys UPI infrastructure
  - Minimal script orchestrates OpenShift operations
  - Deploy CoCo pattern (100% internal)

Truly Disconnected: All ignition, git, and images served from bastion
```

## Key Design Principles

1. **Terraform-First**: Infrastructure as declarative code, not imperative shell scripts
2. **Minimal Shell**: Scripts only orchestrate OpenShift operations, not infrastructure
3. **Truly Disconnected**: Bastion serves ignition configs (http://10.0.1.4:8081/), git (port 8080), and images (ACR)
4. **Idempotent**: Terraform state management allows safe re-runs
5. **Maintainable**: Clear separation between infrastructure (Terraform) and operations (shell)

## Prerequisites

### On Developer Workstation
- Azure credentials (RHDP environment variables)
- Terraform >= 1.0
- SSH client
- Git

### Required RHDP Environment Variables
```bash
export GUID=xxxxx
export CLIENT_ID=xxxxx
export PASSWORD=xxxxx
export TENANT=xxxxx
export SUBSCRIPTION=xxxxx
export RESOURCEGROUP=xxxxx
```

### Additional Requirements
- OpenShift pull secret at `~/pull-secret.json`
- SSH key pair at `~/.ssh/id_rsa` (will be generated if missing)

## Quick Start

### Stage 1: Provision Infrastructure (from workstation)

1. Ensure environment variables are set:
   ```bash
   source .envrc  # or set variables manually
   ```

2. Run provisioning script:
   ```bash
   ./provision.sh eastus
   ```
   
This will:
  - Create Terraform infrastructure (VNet, ACR, bastion with RHEL 10, etc.)
  - Bastion automatically configured via cloud-init on first boot
  - Output connection details
  - Save configuration to `infrastructure-outputs.env`

3. Configure the bastion host:
   ```bash
   ./configure-bastion.sh
   ```
   
   This will:
   - Wait for cloud-init to complete (tools installed automatically)
   - Configure Azure credentials
   - Clone pattern repository to bastion (same fork/branch as your workstation)
   
   **Note**: The bastion uses cloud-init to automatically install tools (including git) during first boot

4. Copy your pull secret to bastion:
   ```bash
   source infrastructure-outputs.env
   scp ~/pull-secret.json ${BASTION_USER}@${BASTION_IP}:~/
   ```

### Stage 2: Mirror and Install (from bastion)

5. SSH to the bastion:
   ```bash
   source infrastructure-outputs.env
   ssh ${BASTION_USER}@${BASTION_IP}
   ```

6. On the bastion, navigate to the pattern directory:
   ```bash
   cd ~/coco-pattern
   ```

7. Run the mirroring process:
   ```bash
   ./rhdp-isolated/bastion/mirror.sh
   ```
   
   This will:
   - Mirror OpenShift 4.20 images to ACR
   - Mirror required operators
   - Mirror CoCo and pattern images
   - Generate IDMS/ITMS manifests
   
   **Note**: This process can take 2-4 hours depending on network speed.

8. Deploy the disconnected cluster (Terraform-first approach):
   ```bash
   ./rhdp-isolated/bastion/deploy-cluster.sh eastasia
   ```
   
   This orchestration script will:
   - **Terraform**: Prepare RHCOS managed image
   - **Python**: Generate disconnected install-config
   - **OpenShift**: Create ignition configs
   - **Terraform**: Copy ignition to bastion HTTP server (http://10.0.1.4:8081/)
   - **Terraform**: Deploy complete UPI infrastructure (DNS, LBs, VMs with static IPs)
   - **OpenShift**: Monitor bootstrap completion
   - **Terraform**: Remove bootstrap VM
   - **OpenShift**: Approve CSRs and complete installation
   - **Helm**: Install CoCo pattern with bastion-served Git and ACR images

   **Key Point**: Infrastructure operations use Terraform (declarative, idempotent), script only orchestrates OpenShift-specific operations.

## Directory Structure (Terraform-First)

```
rhdp-isolated/
├── README.md                           # This file (updated for Terraform-first)
├── TRULY_DISCONNECTED_SOLUTION.md      # Architecture deep-dive
├── ROOT_CAUSE_ANALYSIS.md              # Why this approach
├── provision.sh                        # Stage 1: Provision base infrastructure
├── configure-bastion.sh                # Stage 1: Configure bastion host
│
├── terraform/                          # Base infrastructure (VNet, bastion, NSG)
│   ├── main.tf                         # VNet, subnets, NSG, bastion VM
│   ├── cloud-init.yaml                 # Bastion setup (ignition HTTP on 8081, git HTTP on 8080)
│   ├── variables.tf
│   ├── outputs.tf
│   └── versions.tf
│
├── terraform-rhcos-image/              # NEW: RHCOS image preparation (Terraform)
│   ├── main.tf                         # Download VHD, upload to storage, create managed image
│   ├── variables.tf
│   └── outputs.tf
│
├── terraform-upi-complete/             # NEW: Complete UPI deployment (Terraform)
│   ├── main.tf                         # DNS, load balancers, VMs with static IPs
│   ├── ignition-deploy.tf              # Copy ignition configs to bastion HTTP server
│   ├── variables.tf
│   ├── outputs.tf
│   └── ignition-shim.json.tpl          # Points to http://10.0.1.4:8081/
│
├── bastion/                            # Stage 2: Minimal orchestration scripts
│   ├── deploy-cluster.sh               # NEW: Minimal orchestration (calls Terraform, OpenShift ops)
│   ├── mirror.sh                       # Mirror images to ACR
│   ├── install-config.yaml.j2          # Template for install-config
│   ├── rhdp-cluster-define-disconnected.py  # Config generator
│   └── imageset-config.yaml            # oc-mirror configuration
│
└── deprecated-scripts-20251113/        # OLD: Shell-heavy wrappers (moved to backup)
    ├── README.md                       # Explains why deprecated
    ├── wrapper-upi-complete.sh         # 463 lines (replaced by 247-line orchestrator + Terraform)
    ├── wrapper-upi.sh
    ├── wrapper-disconnected.sh
    ├── fix-cluster-nsg.sh              # Race condition hack (no longer needed)
    └── terraform-upi/                  # Incomplete UPI attempt
```

## What Changed (Terraform-First Refactoring)

| Aspect | Old (Shell-Heavy) | New (Terraform-First) |
|--------|-------------------|----------------------|
| **RHCOS Image** | 150 lines bash with `az` CLI | 100 lines Terraform (declarative) |
| **Ignition Deploy** | `cp` and `scp` commands | Terraform `null_resource` with triggers |
| **VM Deployment** | Terraform + shell wrapper | Pure Terraform module |
| **Orchestration** | 463-line monolithic script | 247-line focused orchestrator |
| **State Management** | Manual tracking | Terraform state |
| **Idempotency** | Complex retry logic | Built-in (Terraform) |
| **Total Lines** | ~663 lines | ~417 lines (-37%) |

**Benefits:**
- ✅ Declarative infrastructure (easier to understand)
- ✅ Idempotent (safe to re-run)
- ✅ State-tracked (Terraform knows what exists)
- ✅ Modular (reusable Terraform modules)
- ✅ Maintainable (clear separation of concerns)

## Troubleshooting

### Cannot connect to bastion
- Verify NSG rules allow SSH from your IP
- Check bastion VM is running: `az vm list -g ${RESOURCEGROUP}`

### Mirroring fails
- Check disk space: `df -h /var/cache/oc-mirror`
- Verify internet connectivity from bastion: `curl -I https://quay.io`
- Check ACR credentials: `podman login ${ACR_LOGIN_SERVER}`

### OpenShift installation fails
- Verify network configuration in install-config.yaml
- Check IDMS/ITMS were applied correctly
- Review installer logs: `openshift-install-disconnected/`.openshift_install.log`

## Cleanup

To destroy all infrastructure:

```bash
cd terraform
terraform destroy
```

## Network Design (Truly Disconnected)

The infrastructure uses a **truly disconnected** model where bastion serves ALL content:

### Bastion Subnet (10.0.1.0/24)
- **NAT Gateway**: Internet access for initial setup and mirroring only
- **Services**:
  - Ignition HTTP Server (port 8081): Serves OpenShift ignition configs
  - Git HTTP Server (port 8080): Serves validated patterns repository
  - ACR Access (port 443): Mirrored container images
- **NSG Rules**: Allows inbound from VirtualNetwork on ports 8080, 8081

### OpenShift Subnets (Master: 10.0.10.0/24, Worker: 10.0.20.0/24)
- **NO Internet Access**: Zero external connectivity
- **NO Azure Storage Access**: No blob.core.windows.net access
- **NO Azure Cloud API Access**: Truly disconnected
- **NSG Rules**:
  - ✅ Allow all traffic within VirtualNetwork
  - ✅ Allow outbound to bastion (10.0.1.0/24) on ports 8080, 8081
  - ❌ **DENY all other Internet outbound**

### Key Architecture Points

1. **Ignition Delivery**: VMs boot with ignition shim pointing to `http://10.0.1.4:8081/{bootstrap,master,worker}.ign`
2. **Git Repository**: ArgoCD fetches patterns from `http://10.0.1.4:8080/coco-pattern`
3. **Container Images**: All pulled from mirrored ACR (accessible within VNet)
4. **Bootstrap IP**: Static `10.0.10.4` (no DHCP conflicts)
5. **Master IPs**: Static `10.0.10.5-7` (consistent DNS/LB targeting)
6. **Worker IPs**: Static `10.0.20.4-6` (predictable networking)

This ensures the OpenShift cluster operates in a **truly disconnected** mode (no Azure Storage, no internet) while allowing the bastion to serve all required content internally.

## Cost Considerations

Key Azure resources and approximate costs:

- ACR Premium: ~$0.833/day
- Bastion VM (Standard_D4s_v5): ~$0.24/hour
- NAT Gateway: ~$0.045/hour + data transfer
- 500GB Premium SSD: ~$81.92/month

Estimated total: ~$150-200/month while running.

Remember to destroy resources when not in use!

