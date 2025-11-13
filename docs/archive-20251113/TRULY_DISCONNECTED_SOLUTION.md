# Truly Disconnected OpenShift Deployment Solution

## Overview

This document describes the implemented solution for deploying OpenShift on Azure in a **truly disconnected** environment where all content (ignition configs, container images, and Git repositories) is served from within the private network, with **ZERO** external dependencies during deployment and runtime.

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│  Disconnected Azure VNet (10.0.0.0/16)                             │
│  No Internet Access | No Azure Storage Access | No Azure Cloud API │
│                                                                      │
│  ┌──────────────────┐                 ┌─────────────────────────┐  │
│  │   Bastion Host   │◄────────────────│  OpenShift VMs          │  │
│  │   10.0.1.4       │   HTTP          │  Masters: 10.0.10.5-7   │  │
│  │                  │                 │  Workers: 10.0.20.4-6   │  │
│  │  Services:       │                 │                         │  │
│  │  ✓ Ignition: 8081│◄────────────────│  Bootstrap: 10.0.10.4   │  │
│  │  ✓ Git: 8080     │   Fetch         │                         │  │
│  │  ✓ ACR: 443      │   configs       │                         │  │
│  └──────────────────┘                 └─────────────────────────┘  │
│                                                                      │
└────────────────────────────────────────────────────────────────────┘
         ↑
         │ SSH Only (22)
         │
     [Operator]
```

## Key Components

### 1. Bastion Host Serves Everything

The bastion host (10.0.1.4) runs three critical services:

#### A. Ignition HTTP Server (Port 8081)
- **Purpose**: Serve OpenShift ignition configs during VM bootstrap
- **Location**: `/var/cache/oc-mirror/ignition/`
- **Service**: `ignition-http.service` (systemd)
- **Access**: `http://10.0.1.4:8081/{bootstrap,master,worker}.ign`

#### B. Git HTTP Server (Port 8080)
- **Purpose**: Serve validated patterns Git repository
- **Location**: `/var/cache/oc-mirror/git/coco-pattern/`
- **Service**: `git-http.service` (systemd)
- **Access**: `http://10.0.1.4:8080/coco-pattern`

#### C. Azure Container Registry (ACR) Mirror (Port 443)
- **Purpose**: Serve mirrored container images
- **Location**: `acr${GUID}.azurecr.io`
- **Content**: All OpenShift, operator, and application images
- **Access**: Via podman/docker with authentication

### 2. Ignition Delivery (The Critical Part)

**The Problem:** Azure VMs have an 87KB limit on `custom_data`, but OpenShift ignition configs are >200KB.

**The Solution:** Two-stage ignition with bastion HTTP server

#### Stage 1: Ignition Shim (Small, fits in 87KB)
```json
{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [
        {
          "source": "http://10.0.1.4:8081/master.ign"
        }
      ]
    }
  }
}
```

#### Stage 2: Full Ignition (Served from Bastion)
- RHCOS VM boots with shim in `custom_data`
- VM fetches full ignition from bastion HTTP server
- VM applies full ignition and continues bootstrap

### 3. Network Security

#### NSG Rules (Truly Disconnected)

**Bastion NSG (`nsg-bastion-${GUID}`)**:
- ✅ Allow SSH (22) from anywhere (operator access)
- ✅ Allow Git HTTP (8080) from VirtualNetwork
- ✅ Allow Ignition HTTP (8081) from VirtualNetwork
- ✅ Allow all outbound (bastion needs freedom for setup)

**OpenShift NSG (`nsg-openshift-${GUID}`)**:
- ✅ Allow all inbound from VirtualNetwork
- ✅ Allow outbound to bastion (10.0.1.0/24) on ports 8080, 8081
- ✅ Allow all outbound to VirtualNetwork
- ❌ **DENY all other Internet outbound**

**No Azure Service Dependencies:**
- ❌ No `Storage` service tag access
- ❌ No `AzureCloud` service tag access
- ❌ No Azure Blob Storage access
- ❌ No Azure ARM API access

### 4. Deployment Flow

#### Phase 1: Infrastructure Provisioning
```bash
cd ~/coco-pattern/rhdp-isolated/terraform
terraform apply
```
Creates:
- VNet, subnets, NSGs
- Bastion VM with cloud-init
- NAT Gateway (for bastion only)

#### Phase 2: Bastion Configuration
```bash
./configure-bastion.sh
```
- Clones pattern repository
- Configures Git HTTP server
- Starts ignition HTTP server
- Sets up ACR authentication

#### Phase 3: Image Mirroring
```bash
ssh azureuser@<bastion-ip>
cd ~/coco-pattern
./rhdp-isolated/bastion/mirror.sh
```
Mirrors all images to ACR

#### Phase 4: OpenShift Installation (UPI)
```bash
ssh azureuser@<bastion-ip>
cd ~/coco-pattern
./rhdp-isolated/bastion/wrapper-upi-complete.sh eastasia
```

**What Happens:**
1. Generate install-config.yaml
2. Generate ignition configs (bootstrap, master, worker)
3. **Copy ignition configs to `/var/cache/oc-mirror/ignition/`** (not Azure Storage!)
4. Generate ignition shim pointing to bastion HTTP URLs
5. Prepare RHCOS managed image
6. Deploy VMs with Terraform:
   - VMs boot with ignition shim in `custom_data`
   - VMs fetch full ignition from `http://10.0.1.4:8081/`
   - VMs apply ignition and bootstrap
7. Wait for bootstrap completion
8. Approve CSRs and admit nodes
9. Decommission bootstrap VM
10. Complete cluster installation

#### Phase 5: Pattern Deployment
```bash
# Pattern install uses bastion-served Git and ACR images
oc apply -f ~/coco-pattern/openshift-install-upi/...
```

## Files Modified

### Cloud-Init Configuration
**File**: `rhdp-isolated/terraform/cloud-init.yaml`
- Added `ignition-http.service` systemd unit
- Creates `/var/cache/oc-mirror/ignition/` directory
- Starts ignition HTTP server on port 8081

### Terraform Infrastructure
**File**: `rhdp-isolated/terraform/main.tf`
- Added NSG rule to allow bastion inbound on port 8081
- Removed Azure Storage and AzureCloud service tag rules
- Added outbound rule to bastion for ports 8080, 8081
- Truly disconnected: Only VNet traffic allowed

### UPI Wrapper Script
**File**: `rhdp-isolated/bastion/wrapper-upi-complete.sh`
- **Removed**: Azure Storage account creation for ignition
- **Removed**: Blob upload to Azure Storage
- **Removed**: SAS token generation
- **Added**: Copy ignition configs to `/var/cache/oc-mirror/ignition/`
- **Added**: Generate bastion HTTP URLs (`http://10.0.1.4:8081/...`)
- **Added**: Verify ignition server accessibility before deployment

### Terraform UPI Variables
**File**: `rhdp-isolated/terraform-upi-complete/variables.tf`
- Added `bastion_ip` variable (default: 10.0.1.4)
- Ignition URL variables now expect HTTP URLs, not SAS URLs

## Advantages of This Solution

### 1. **Truly Disconnected**
- ✅ Zero external dependencies during bootstrap
- ✅ Zero external dependencies during runtime
- ✅ All content served from within the private VNet
- ✅ Meets strict air-gapped environment requirements

### 2. **Client Requirement Compliance**
- ✅ **All images mirrored into environment** (ACR)
- ✅ **All configs served internally** (bastion HTTP)
- ✅ **All code served internally** (bastion Git HTTP)
- ✅ No Azure Storage dependency
- ✅ No internet access required

### 3. **Reliable and Repeatable**
- ✅ No race conditions with NSG timing
- ✅ No dependency on CAPI behavior
- ✅ No SAS token expiry issues
- ✅ Simple HTTP server, no complex Azure setup

### 4. **OpenShift Native**
- ✅ Uses standard ignition delivery mechanism
- ✅ Compatible with RHCOS expectations
- ✅ No custom ignition modifications
- ✅ Works with OpenShift 4.20+

### 5. **Secure**
- ✅ Internal-only traffic
- ✅ No public internet exposure
- ✅ Bastion-only SSH access
- ✅ Defense in depth with NSG layers

## Limitations and Considerations

### 1. Bastion Single Point of Failure
- **Impact**: If bastion is down during deployment, VMs cannot fetch ignition
- **Mitigation**: Ensure bastion is stable before starting deployment
- **Future**: Could implement redundant bastion or HA ignition server

### 2. Bastion Must Be Running During Bootstrap
- **Impact**: Bastion must remain accessible during initial VM provisioning
- **Duration**: ~20-30 minutes for bootstrap phase
- **Note**: After cluster is up, bastion can be stopped if not needed

### 3. Network Routing
- **Requirement**: Master and worker subnets must have routes to bastion subnet
- **Current**: Handled by default VNet routing (all subnets can reach each other)
- **Note**: If custom route tables are used, ensure bastion reachability

### 4. HTTP (Not HTTPS)
- **Security**: Ignition and Git served over HTTP, not HTTPS
- **Risk**: Low - all traffic is within private VNet
- **Mitigation**: Traffic doesn't leave the VNet, NSG controls access
- **Future**: Could add self-signed certs if required

## Testing Checklist

Before declaring success, verify:

- [ ] Bastion ignition HTTP server is running (`systemctl status ignition-http.service`)
- [ ] Bastion Git HTTP server is running (`systemctl status git-http.service`)
- [ ] Ignition files are accessible: `curl http://10.0.1.4:8081/bootstrap.ign`
- [ ] NSG rules allow master/worker → bastion on ports 8080, 8081
- [ ] NSG rules DENY all Internet outbound except VNet
- [ ] Bootstrap VM successfully fetches ignition from bastion
- [ ] Master VMs successfully fetch ignition from bastion
- [ ] Worker VMs successfully fetch ignition from bastion
- [ ] Cluster installation completes without Azure Storage access
- [ ] Pattern installs using bastion Git and ACR images

## Deployment Commands

### Full Deployment (From Scratch)
```bash
# 1. Provision infrastructure (from local machine)
cd ~/go/src/github.com/butler54/coco-pattern/rhdp-isolated/terraform
source ../../.envrc
terraform init
terraform apply -auto-approve

# 2. Configure bastion (from local machine)
cd ..
./configure-bastion.sh

# 3. Mirror images (on bastion, takes ~2-3 hours)
ssh azureuser@<bastion-ip>
cd ~/coco-pattern
./rhdp-isolated/bastion/mirror.sh

# 4. Deploy OpenShift (on bastion, takes ~45-60 minutes)
cd ~/coco-pattern
./rhdp-isolated/bastion/wrapper-upi-complete.sh eastasia

# 5. Monitor progress
oc --kubeconfig openshift-install-upi/auth/kubeconfig get nodes
oc --kubeconfig openshift-install-upi/auth/kubeconfig get co
```

### Verify Truly Disconnected
```bash
# On OpenShift node (via debug pod)
oc debug node/<node-name>
chroot /host

# Try to reach internet (should fail)
curl -I https://www.google.com      # Should timeout/fail
curl -I https://redhat.com           # Should timeout/fail
curl -I https://quay.io              # Should timeout/fail

# Try to reach Azure Storage (should fail)
curl -I https://<storage-account>.blob.core.windows.net  # Should timeout/fail

# Verify can reach bastion (should succeed)
curl -I http://10.0.1.4:8081/        # Should return 200 OK
curl -I http://10.0.1.4:8080/        # Should return 200 OK
```

## Comparison: Previous vs. Current Approach

| Aspect | Previous (Hybrid) | Current (Truly Disconnected) |
|--------|------------------|------------------------------|
| **Ignition Delivery** | Azure Blob Storage | Bastion HTTP Server |
| **Internet Access** | Required during bootstrap | ZERO at all times |
| **Azure Storage** | Required | Not used |
| **Azure Cloud API** | Required | Not used |
| **NSG Complexity** | Complex with service tags | Simple VNet rules |
| **Deployment Reliability** | Timing sensitive | Rock solid |
| **Client Requirements** | Partially met | Fully met |
| **Security Posture** | "Restricted" | Truly Disconnected |

## Troubleshooting

### Ignition Server Not Accessible
```bash
# On bastion
systemctl status ignition-http.service
curl http://localhost:8081/bootstrap.ign

# Check firewall
sudo firewall-cmd --list-all

# Check ignition files exist
ls -la /var/cache/oc-mirror/ignition/
```

### VMs Fail to Bootstrap
```bash
# Check NSG rules
az network nsg rule list -g openenv-p54kj --nsg-name nsg-openshift-p54kj -o table

# Check from bastion (simulate VM)
curl -I http://10.0.1.4:8081/master.ign

# Check VM serial console in Azure Portal for boot errors
```

### Pattern Install Fails
```bash
# Check Git server
systemctl status git-http.service
curl http://10.0.1.4:8080/coco-pattern/.git/config

# Check ACR access
podman login acr${GUID}.azurecr.io
```

## Success Criteria

✅ **Deployment succeeds with:**
- Zero Azure Storage access attempts
- Zero Azure Cloud API access (except ACR)
- All ignition fetches from bastion HTTP
- All images pulled from mirrored ACR
- All Git operations from bastion HTTP

✅ **NSG logs show:**
- No blocked Azure Storage traffic (because none attempted)
- No blocked Azure Cloud traffic (because none attempted)
- Only VNet and bastion HTTP traffic

✅ **Cluster is operational:**
- All nodes are Ready
- All cluster operators are Available
- Pattern is deployed and functional
- Workloads can run

---

**This is the solution that meets the client requirement: "images must be mirrored into the environment."**

Everything - ignition configs, container images, and Git repositories - is served from within the disconnected network. No external dependencies at any stage.

**Date**: 2025-11-13  
**Status**: Implementation Complete - Ready for Testing

