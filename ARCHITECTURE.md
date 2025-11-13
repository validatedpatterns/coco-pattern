# OpenShift Confidential Containers - Disconnected Azure Deployment

**Version**: 2.0  
**Date**: 2025-11-13  
**Status**: Production Ready

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Network Security](#network-security)
4. [Bastion Services](#bastion-services)
5. [Deployment Flow](#deployment-flow)
6. [Terraform-First Design](#terraform-first-design)
7. [Troubleshooting](#troubleshooting)
8. [Verified Assumptions](#verified-assumptions)

---

## Overview

### What This Is

A **Terraform-managed, cloud-init-automated** deployment system for OpenShift with Confidential Containers (CoCo) on Azure in a **disconnected environment** where:

- ✅ All container images are mirrored into bastion-hosted registry
- ✅ All ignition configs served from bastion
- ✅ All Git operations use bastion HTTP server
- ✅ Cluster has NO general internet access
- ✅ Cluster CAN access Azure management APIs (for VM provisioning)
- ✅ Fresh deployments require ZERO manual configuration

### Why This Approach

**Client Requirement**: All images must be mirrored into the environment (no external registries).

**Key Design Decisions**:
1. **Bastion-Hosted Registry**: Simpler than ACR, truly self-contained
2. **Cloud-Init Self-Contained**: All configuration automated via Terraform variables
3. **Terraform-First**: Infrastructure as declarative code, not imperative scripts
4. **Azure API Access**: Required for cluster VM provisioning and management
5. **UPI (User-Provisioned Infrastructure)**: Full control over networking and bootstrap process

---

## Architecture

### System Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│  Disconnected Azure VNet (10.0.0.0/16)                               │
│                                                                        │
│  ┌─────────────────────┐              ┌──────────────────────────┐  │
│  │   Bastion Host      │◄─────────────│  OpenShift Cluster       │  │
│  │   10.0.1.4          │              │                          │  │
│  │                     │              │  Masters: 10.0.10.5-7    │  │
│  │  Services:          │   HTTP       │  Workers: 10.0.20.4-6    │  │
│  │  • Registry  :5000  │◄─────────────│  Bootstrap: 10.0.10.4    │  │
│  │  • Git       :8080  │   Fetch      │                          │  │
│  │  • Ignition  :8081  │   Content    │  VMs fetch from bastion: │  │
│  │                     │              │  - Images (5000)         │  │
│  │  NAT Gateway for    │              │  - Git (8080)            │  │
│  │  initial setup      │              │  - Ignition (8081)       │  │
│  └─────────────────────┘              └──────────────────────────┘  │
│         ↑                                        ↓                    │
│         │ SSH Only (22)               Azure APIs (443)                │
└─────────┼──────────────────────────────────┼───────────────────────┘
          │                                  │
     [Operator]                      [AzureCloud Service Tag]
                                      (VM provisioning, auth,
                                       cluster management)
```

### Component Breakdown

#### Bastion Host (10.0.1.4)
- **OS**: RHEL 10 (latest)
- **Size**: Standard_D4s_v5 (4 vCPU, 16GB RAM)
- **Disks**: 
  - OS: 512GB Premium SSD
  - Data: 500GB Premium SSD (`/var/cache/oc-mirror`)
- **Connectivity**: 
  - Public IP for operator SSH access
  - NAT Gateway for internet (tools download, image mirroring)
- **Services**: All auto-configured by cloud-init
  - Container Registry (podman, port 5000)
  - Git HTTP Server (python, port 8080)
  - Ignition HTTP Server (python, port 8081)

#### OpenShift Cluster
- **Architecture**: UPI (User-Provisioned Infrastructure)
- **Version**: 4.20.x
- **Nodes**: 
  - 3 Masters (Standard_D8s_v5, static IPs: 10.0.10.5-7)
  - 3 Workers (Standard_D8s_v5, static IPs: 10.0.20.4-6)
  - 1 Bootstrap (ephemeral, removed after installation)
- **Networking**: Private subnets, NO internet, YES Azure APIs
- **Image Source**: Bastion registry only (10.0.1.4:5000)

---

## Network Security

### NSG Rules Summary

#### Bastion NSG (`nsg-bastion-{guid}`)

| Priority | Name | Direction | Protocol | Port | Source | Destination | Purpose |
|----------|------|-----------|----------|------|--------|-------------|---------|
| 1001 | AllowSSH | Inbound | TCP | 22 | * | * | Operator access |
| 1002 | AllowGitHTTP | Inbound | TCP | 8080 | VirtualNetwork | * | Git server access from cluster |
| 1003 | AllowIgnitionHTTP | Inbound | TCP | 8081 | VirtualNetwork | * | Ignition server access from cluster VMs |
| 1004 | AllowRegistryHTTP | Inbound | TCP | 5000 | VirtualNetwork | * | Registry access from cluster |
| 1005 | AllowOutbound | Outbound | * | * | * | * | Bastion needs internet for setup |

#### OpenShift NSG (`nsg-openshift-{guid}`)

| Priority | Name | Direction | Protocol | Port | Source | Destination | Purpose |
|----------|------|-----------|----------|------|--------|-------------|---------|
| 1001 | AllowVNetInbound | Inbound | * | * | VirtualNetwork | * | Internal cluster communication |
| 1000 | AllowBastionServices | Outbound | TCP | 5000,8080,8081 | * | 10.0.1.0/24 | Access bastion services |
| 1001 | AllowAzureCloudAPIs | Outbound | TCP | 443 | * | AzureCloud | VM provisioning, cluster mgmt |
| 1002 | AllowVNetOutbound | Outbound | * | * | * | VirtualNetwork | Internal cluster communication |
| 4096 | DenyInternetOutbound | Outbound | * | * | * | Internet | Block general internet |

### Why Azure Cloud APIs Are Allowed

**Service Tag**: `AzureCloud`  
**Purpose**: Enable cluster to function on Azure while remaining disconnected from public internet

**What AzureCloud Allows**:
- ✅ Azure Resource Manager (ARM) - VM provisioning, resource management
- ✅ Azure Active Directory (AAD) - Authentication
- ✅ Azure Metadata Service - Instance metadata
- ✅ Azure DNS - Name resolution for Azure services

**What's Still Blocked**:
- ❌ General internet (websites, external APIs)
- ❌ GitHub, Quay.io, DockerHub (use bastion registry instead)
- ❌ Public container registries (all images from bastion)

This configuration is **internet-disconnected** but **Azure-functional**.

---

## Bastion Services

### 1. Container Registry (Port 5000)

**Technology**: Podman running `docker.io/library/registry:2`  
**Storage**: `/var/cache/oc-mirror/registry/data` (500GB data disk)  
**Access**: `http://10.0.1.4:5000`  
**Authentication**: None required (internal use only)

**Purpose**: 
- Hosts all mirrored OpenShift platform images
- Hosts all mirrored operators (ACM, MCE, GitOps, Sandboxed Containers)
- Hosts all application images (CoCo pattern apps)

**Verification**:
```bash
curl http://10.0.1.4:5000/v2/
# Should return: {}
```

**Service Management**:
```bash
systemctl status registry.service
systemctl restart registry.service
journalctl -u registry.service -f
```

### 2. Git HTTP Server (Port 8080)

**Technology**: Python `http.server`  
**Location**: `/var/cache/oc-mirror/git/coco-pattern` (bare repository)  
**Access**: `http://10.0.1.4:8080/coco-pattern`

**Purpose**:
- Serves validated patterns Git repository to OpenShift cluster
- ArgoCD fetches patterns from this server (GitHub not accessible)

**Verification**:
```bash
curl http://10.0.1.4:8080/coco-pattern/.git/HEAD
# Should return: ref: refs/heads/...
```

**Service Management**:
```bash
systemctl status git-http.service
systemctl restart git-http.service
```

### 3. Ignition HTTP Server (Port 8081)

**Technology**: Python `http.server`  
**Location**: `/var/cache/oc-mirror/ignition/`  
**Access**: `http://10.0.1.4:8081/`

**Purpose**:
- Serves OpenShift ignition configs during VM bootstrap
- Solves Azure 87KB `custom_data` limit with ignition shim

**Verification**:
```bash
curl http://10.0.1.4:8081/bootstrap.ign
# Should return JSON ignition config
```

**Service Management**:
```bash
systemctl status ignition-http.service
systemctl restart ignition-http.service
```

---

## Deployment Flow

### Prerequisites

**On Operator Workstation**:
- Azure service principal credentials (in `.envrc` or environment)
- Terraform >= 1.0
- SSH client
- Red Hat OpenShift pull secret (`~/pull-secret.json`)

### Stage 1: Provision Infrastructure (10-15 minutes)

**Command** (from workstation):
```bash
cd rhdp-isolated
source ../.envrc  # Sets GUID, CLIENT_ID, PASSWORD, TENANT, SUBSCRIPTION, RESOURCEGROUP
./provision.sh eastasia
```

**What Happens**:
1. **Terraform** creates Azure infrastructure:
   - VNet, subnets, NSG rules
   - NAT Gateway
   - Bastion VM with 500GB data disk
   - Private DNS zone for blob storage
2. **Cloud-Init** (runs automatically on bastion first boot):
   - Installs packages (git, podman, python, azure-cli, OpenShift tools)
   - Mounts 500GB data disk
   - Creates Azure credentials from Terraform vars
   - Creates `.envrc` with registry URL, Azure auth
   - Generates SSH key pair
   - Clones pattern repository (from Terraform git_remote_url/git_branch)
   - Starts container registry (podman on port 5000)
   - Starts Git HTTP server (port 8080)
   - Starts ignition HTTP server (port 8081)
3. **Outputs** saved to `infrastructure-outputs.env`

**Result**: Bastion is **100% ready** for deployment (no manual configuration needed).

### Stage 2: Verify Configuration (1-2 minutes)

**Command** (from workstation):
```bash
./configure-bastion.sh
```

**What Happens**:
- Waits for cloud-init to complete (uses `sudo cloud-init status`)
- Verifies all files exist:
  - Azure credentials ✅
  - Environment variables ✅
  - SSH key ✅
  - Pattern repository ✅
  - Registry service running ✅
  - Git service running ✅
  - Ignition service running ✅
- **No configuration** (only verification)

**Result**: Confirmation that bastion is ready, or error if cloud-init failed.

### Stage 3: Copy Pull Secret (instant)

**Command** (from workstation):
```bash
scp ~/pull-secret.json azureuser@<bastion-ip>:~/
```

**Why Manual**: Pull secret contains sensitive Red Hat credentials, cannot be automated.

### Stage 4: Deploy Cluster (2.5-5 hours first time, 45-60 min subsequent)

**Command** (from bastion):
```bash
ssh azureuser@<bastion-ip>
cd ~/coco-pattern
./rhdp-isolated/bastion/deploy-cluster.sh eastasia
```

**What Happens** (fully automated):

**Step 0: Auto-Mirroring** (2-4 hours, only if not already done)
- Checks if `cluster-resources/` exists
- If not, automatically runs `mirror.sh`:
  - Merges Red Hat pull secret with registry auth
  - Runs `oc-mirror` to mirror all images to `localhost:5000`
  - Generates IDMS/ITMS manifests
  - Copies manifests to `cluster-resources/`
- Skips if already complete

**Step 1: Terraform Prepares RHCOS Image** (5-10 minutes)
- Downloads RHCOS VHD from Red Hat
- Uploads to Azure Storage (bastion has NAT for this)
- Creates Azure managed image

**Step 2: Generate Install Config** (instant)
- Python script creates `install-config.yaml`
- Includes IDMS from mirroring
- Configures for UPI with static IPs

**Step 3: Generate Ignition Configs** (instant)
- `openshift-install create ignition-configs`
- Creates bootstrap.ign, master.ign, worker.ign

**Step 4: Terraform Deploys UPI Infrastructure** (15-20 minutes)
- Copies ignition configs to `/var/cache/oc-mirror/ignition/`
- Creates Private DNS zone
- Creates load balancers (external and internal API)
- Creates VMs with ignition shims pointing to `http://10.0.1.4:8081/`
- VMs boot and fetch full ignition from bastion

**Step 5: Monitor Bootstrap** (20-30 minutes)
- `openshift-install wait-for bootstrap-complete`
- Bootstrap VM runs etcd and temporary control plane
- Masters join and take over

**Step 6: Terraform Removes Bootstrap** (2 minutes)
- `terraform destroy -target bootstrap`
- Cleans up bootstrap VM, disk, NIC

**Step 7: Approve CSRs** (5-10 minutes)
- Auto-approves master and worker CSRs in loop
- Waits for all 6 nodes to be Ready
- `openshift-install wait-for install-complete`

**Step 8: Install Pattern** (10-15 minutes)
- Helm deploys validated pattern
- ArgoCD fetches from bastion Git server
- All images pulled from bastion registry
- CoCo operators deployed

**Result**: Fully functional OpenShift cluster with CoCo pattern.

---

## Terraform-First Design

### Principle

**Infrastructure operations use Terraform (declarative, state-tracked, idempotent).**  
**Shell scripts ONLY orchestrate OpenShift operations.**

### Why This Matters

**Before (Shell-Heavy)**:
- 663 lines of bash doing infrastructure operations
- Manual state tracking
- Complex retry logic
- Hard to resume from failures

**After (Terraform-First)**:
- 417 lines total (37% reduction)
- Terraform state tracks all infrastructure
- Built-in idempotency
- Easy to resume (`terraform apply` picks up where it left off)

### Module Structure

```
rhdp-isolated/
├── terraform/                   # Base infrastructure
│   ├── main.tf                  # VNet, NSG, bastion
│   ├── cloud-init.yaml          # Self-contained bastion setup
│   ├── variables.tf
│   ├── outputs.tf
│   └── versions.tf
│
├── terraform-rhcos-image/       # RHCOS image preparation
│   ├── main.tf                  # Download, upload VHD, create image
│   ├── variables.tf
│   └── outputs.tf
│
├── terraform-upi-complete/      # Complete UPI deployment
│   ├── main.tf                  # DNS, LBs, VMs with static IPs
│   ├── ignition-deploy.tf       # Copy ignition to bastion HTTP
│   ├── variables.tf
│   ├── outputs.tf
│   └── ignition-shim.json.tpl   # Points to http://10.0.1.4:8081/
│
└── bastion/                     # Minimal orchestration scripts
    ├── deploy-cluster.sh        # Orchestrates Terraform + OpenShift ops
    ├── mirror.sh                # oc-mirror to bastion registry
    └── rhdp-cluster-define-disconnected.py
```

### Benefits

| Aspect | Shell | Terraform |
|--------|-------|-----------|
| **State Management** | Manual | Automatic |
| **Idempotency** | Complex logic | Built-in |
| **Resume from Failure** | Hard | Easy (`terraform apply`) |
| **Debugging** | Print statements | `terraform plan` |
| **Version Control** | Scripts | Declarative config |

---

## Troubleshooting

### Cloud-Init Failed

**Symptoms**: `configure-bastion.sh` reports missing files

**Diagnosis**:
```bash
ssh azureuser@<bastion-ip>
sudo cloud-init status --long
sudo cat /var/log/cloud-init.log | tail -100
```

**Common Causes**:
- YAML syntax error in `cloud-init.yaml`
- Network timeout downloading tools
- Disk mount failure

**Fix**: Check logs, fix cloud-init.yaml, redeploy bastion

### Registry Not Accessible

**Symptoms**: `mirror.sh` fails with "Cannot access bastion registry"

**Diagnosis**:
```bash
ssh azureuser@<bastion-ip>
systemctl status registry.service
curl http://localhost:5000/v2/
podman ps | grep registry
```

**Common Causes**:
- Registry container failed to start
- Port 5000 conflict
- Disk space full

**Fix**:
```bash
sudo systemctl restart registry.service
sudo podman logs registry
df -h /var/cache/oc-mirror
```

### Image Pull Failures on Cluster

**Symptoms**: Pods stuck in `ImagePullBackOff`

**Diagnosis**:
```bash
oc describe pod <pod-name>
# Check events for registry errors
```

**Common Causes**:
- NSG blocking port 5000
- Registry service down
- Image not mirrored

**Fix**:
```bash
# On bastion
systemctl status registry.service
curl http://10.0.1.4:5000/v2/_catalog  # List all images

# Check NSG rules allow port 5000
az network nsg rule list -g ${RESOURCEGROUP} --nsg-name nsg-openshift-${GUID}
```

### VM Provisioning Timeout

**Symptoms**: Masters/Workers fail with `OSProvisioningTimedOut`

**Diagnosis**:
- Check NSG allows AzureCloud outbound (priority 1001)
- Check ignition server has bootstrap.ign, master.ign, worker.ign
- SSH to bootstrap and check ignition fetch logs

**Common Causes**:
- NSG blocking Azure APIs
- Ignition server down
- Ignition files missing

**Fix**:
```bash
# Verify NSG rule exists
az network nsg rule show -g ${RESOURCEGROUP} --nsg-name nsg-openshift-${GUID} -n AllowAzureCloudAPIs

# Verify ignition server
ssh azureuser@<bastion-ip>
systemctl status ignition-http.service
ls -la /var/cache/oc-mirror/ignition/
```

---

## Verified Assumptions

Based on code review and testing:

1. ✅ **Cluster cannot access internet**: `DenyInternetOutbound` NSG rule (priority 4096)
2. ✅ **Cluster CAN access Azure API endpoints**: `AllowAzureCloudAPIs` rule allows `AzureCloud` service tag
3. ✅ **All container images mirrored**: `oc-mirror` runs to bastion registry (localhost:5000)
4. ✅ **Bastion runs oc-mirror**: Stage 0 in `deploy-cluster.sh` (auto-runs if needed)
5. ✅ **Bastion hosts Git**: `git-http.service` on port 8080, auto-started by cloud-init
6. ✅ **Ignition hosted on bastion**: `ignition-http.service` on port 8081, VMs fetch via HTTP
7. ✅ **Blob storage not used by cluster**: Only bastion uses blob storage for RHCOS VHD upload
8. ✅ **NSG isolates from internet, allows Azure APIs**: Explicit rules enforce this

### Network Access Matrix

| Component | Internet | Azure APIs | Blob Storage | Bastion Registry | Bastion Git | Bastion Ignition |
|-----------|----------|------------|--------------|------------------|-------------|------------------|
| **Operator Workstation** | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **Bastion** | ✅ (NAT) | ✅ | ✅ | ✅ (localhost) | ✅ (localhost) | ✅ (localhost) |
| **OpenShift Masters** | ❌ | ✅ | ❌ | ✅ (10.0.1.4:5000) | ✅ (10.0.1.4:8080) | ✅ (10.0.1.4:8081) |
| **OpenShift Workers** | ❌ | ✅ | ❌ | ✅ (10.0.1.4:5000) | ✅ (10.0.1.4:8080) | ❌ |

---

## Quick Reference

### Fresh Deployment Commands

```bash
# 1. Provision infrastructure (from workstation)
cd rhdp-isolated
source ../.envrc
./provision.sh eastasia
# Duration: 10-15 minutes
# Cloud-init auto-configures bastion (adds ~5 minutes)

# 2. Verify bastion (from workstation)
./configure-bastion.sh
# Duration: 1-2 minutes
# Just verification, no configuration

# 3. Copy pull secret (from workstation)
scp ~/pull-secret.json azureuser@<bastion-ip>:~/
# Duration: instant

# 4. Deploy cluster (from bastion)
ssh azureuser@<bastion-ip>
cd ~/coco-pattern
./rhdp-isolated/bastion/deploy-cluster.sh eastasia
# Duration: 2.5-5 hours first time (includes auto-mirroring)
#           45-60 minutes if mirroring already done
```

### Service URLs

- **Bastion SSH**: `ssh azureuser@<public-ip>`
- **Container Registry**: `http://10.0.1.4:5000/v2/`
- **Git Server**: `http://10.0.1.4:8080/coco-pattern`
- **Ignition Server**: `http://10.0.1.4:8081/`
- **OpenShift Console**: `https://console-openshift-console.apps.<cluster>.<domain>`

### Key Files

- **Terraform State**: `rhdp-isolated/terraform/terraform.tfstate`
- **Pull Secret**: `~/pull-secret.json` (on bastion)
- **Kubeconfig**: `~/coco-pattern/openshift-install-upi/auth/kubeconfig`
- **Admin Password**: `~/coco-pattern/openshift-install-upi/auth/kubeadmin-password`
- **Mirrored Manifests**: `~/coco-pattern/cluster-resources/`

---

## Design Principles

1. **Self-Contained Cloud-Init**: All bastion configuration from Terraform variables
2. **Bastion Serves Everything**: Registry, Git, Ignition all on bastion
3. **Terraform-First**: Infrastructure as code, scripts for operations only
4. **Maximize Automation**: Auto-run mirroring, auto-configure bastion
5. **Minimal Manual Steps**: Only copy pull secret (sensitive)
6. **Internet-Disconnected**: Cluster has zero public internet access
7. **Azure-Functional**: Cluster can provision VMs and manage Azure resources

---

**This architecture meets client requirements**: All images mirrored into environment, truly disconnected from public internet, but Azure-functional for cluster operations.

