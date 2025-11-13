# OpenShift Azure Disconnected Deployment - Root Cause Analysis

## Executive Summary

After multiple deployment failures and extensive troubleshooting, the root cause has been identified: **OpenShift on Azure has a fundamental architectural conflict with truly disconnected environments during the bootstrap phase.**

## The Fundamental Problem

### 1. Azure Custom Data Size Limit (87KB)
- Azure VMs accept configuration via `custom_data` parameter
- Maximum size: **87KB** (base64 encoded)
- OpenShift ignition configs for masters/workers: **>200KB typically**
- **Consequence**: Full ignition configs cannot be embedded directly in VM `custom_data`

### 2. The Ignition Shim Workaround
Red Hat's standard solution uses a two-stage approach:
```json
{
  "ignition": {
    "version": "3.4.0",
    "config": {
      "replace": {
        "source": "https://<storage-account>.blob.core.windows.net/<container>/master.ign?<SAS-token>"
      }
    }
  }
}
```

This small "shim" config (fits in 87KB) tells RHCOS:
1. Boot using this minimal ignition
2. Fetch the **real** ignition config from the Azure Storage URL
3. Apply the real config and continue bootstrapping

### 3. The Disconnected Conflict

**In our truly disconnected environment:**
- NSG rules deny all outbound internet traffic (except specific Azure service tags)
- Even with `Storage` service tag allowed, VMs in **private subnets** cannot reach `*.blob.core.windows.net` without:
  - NAT Gateway for SNAT
  - AND Service Endpoints for routing
  - AND NSG rules for authorization

**But here's the catch:**
- During initial VM boot (ignition phase), VMs attempt to fetch from Blob Storage
- If network isn't fully configured yet, or if there's any timing issue, they timeout
- This results in: `OSProvisioningTimedOut` after 20 minutes

## What We Tried (And Why Each Failed)

### Attempt 1: IPI with Dynamic NSG Fix
- **Approach**: Start with permissive NSG, let CAPI create cluster, then dynamically apply restrictive rules
- **Failure**: Race condition - CAPI creates its own NSG and overwrites our rules
- **Lesson**: CAPI reconciliation defeats post-hoc NSG configuration

### Attempt 2: IPI with Subnet-Level NSG
- **Approach**: Pre-configure NSG on subnets before installation
- **Failure**: CAPI still creates VM-level NSGs that override subnet NSG
- **Lesson**: CAPI's declarative reconciliation isn't designed for pre-existing security configurations

### Attempt 3: IPI with Static Bootstrap IP
- **Approach**: Use `bootstrapExternalStaticIP` to fix IP mismatch issue
- **Failure**: This parameter is not supported for Azure IPI
- **Lesson**: Not all documented parameters work on all platforms

### Attempt 4: UPI with Terraform-Provisioned VMs
- **Approach**: Manually create all infrastructure including VMs with static IPs
- **Failure**: VMs failed `OSProvisioningTimedOut` because they couldn't fetch ignition from Blob Storage
- **Root Cause**: Our disconnected NSG rules prevented access to Azure Blob Storage during boot
- **Lesson**: Ignition delivery via Azure Storage is incompatible with truly disconnected networks

### Attempt 5: UPI with Full DNS/LB Infrastructure
- **Approach**: Added Private DNS, Load Balancers, complete UPI infrastructure
- **Status**: Still failed at ignition fetch stage
- **Lesson**: Infrastructure completeness doesn't solve the ignition delivery problem

## The Hard Truth

**OpenShift on Azure is NOT designed for truly disconnected environments out of the box.**

The architecture assumes:
1. VMs can reach Azure Blob Storage during bootstrap
2. This requires outbound connectivity (even if Azure-internal)
3. "Restricted network" in Red Hat docs means "limited internet, but Azure services accessible"

## Actual Red Hat Recommended Approach

From Red Hat documentation (https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/installing_on_azure/index#installing-restricted-networks-azure-installer-provisioned):

**"Restricted Network" ≠ "Fully Disconnected"**

Red Hat's "restricted network" installation:
- Still allows Azure platform services (Storage, ARM, AAD) access
- Uses `outboundType: UserDefinedRouting` with NAT Gateway
- Blocks general internet but permits Azure service endpoints
- **Requires storage account accessibility during bootstrap**

## Why Our Approach Was Flawed

We interpreted "disconnected" as:
- **Zero** outbound internet connectivity
- **Zero** access to Azure public services
- Only bastion accessible via SSH

This is **more restrictive** than Red Hat's design supports for Azure.

## Possible Solutions (In Order of Feasibility)

### Solution 1: Accept "Restricted" Not "Fully Disconnected" ✅ **RECOMMENDED**
- Allow Azure Storage access via:
  - NAT Gateway for outbound SNAT
  - Service Endpoints for efficient routing
  - NSG rule allowing `Storage.EastAsia` service tag
- Block all other internet traffic
- This is Red Hat's intended "restricted network" model
- **Pros**: Officially supported, tested, documented
- **Cons**: Not truly disconnected during bootstrap

### Solution 2: Bastion-Hosted Ignition Server 🔶 **COMPLEX**
- Host ignition configs on bastion HTTP server
- Modify ignition shims to point to: `http://10.0.1.4:8080/ignition/master.ign`
- Requires:
  - Custom routes from master/worker subnets to bastion subnet
  - NSG rules to allow port 8080 from VMs to bastion
  - Ignition shim generation with bastion URL (not SAS URL)
- **Pros**: Truly disconnected (no Azure Storage dependency)
- **Cons**: Unsupported, requires deep OpenShift customization, fragile

### Solution 3: Split Ignition into Multiple Small Configs 🔶 **EXPERIMENTAL**
- Split master/worker ignition into modular pieces
- Use systemd oneshot services to fetch and merge on first boot
- Requires custom ignition generation
- **Pros**: Avoids external URL fetch
- **Cons**: Very complex, error-prone, unsupported

### Solution 4: Use Azure Private Endpoints ⚠️ **PARTIAL**
- Create Azure Private Endpoint for Storage Account
- This gives storage account a private IP in the VNet
- Modify ignition shims to use private endpoint FQDN
- **Pros**: No public internet required
- **Cons**: Still requires NAT Gateway for other Azure APIs, complex DNS setup

### Solution 5: Post-Bootstrap Lockdown ✅ **PRAGMATIC**
- Deploy with permissive NSG (allow Azure Storage)
- Complete installation successfully
- After cluster is up, apply restrictive NSG
- **Pros**: Gets cluster running, then locks down
- **Cons**: Brief window of Azure Storage access

## Recommended Path Forward

Given the constraints and Red Hat's architecture, I recommend:

### **Hybrid Approach: Permissive Bootstrap + Post-Install Lockdown**

1. **Phase 1: Bootstrap with Azure Storage Access**
   - Deploy with NSG allowing:
     - `Storage.EastAsia` on port 443
     - `AzureCloud` on port 443
     - `VirtualNetwork` on all ports
   - Deploy via IPI or UPI with proper ignition delivery via Azure Storage
   - Complete cluster installation

2. **Phase 2: Pattern Deployment**
   - Use bastion-hosted Git server for pattern repository
   - Use ACR (already mirrored) for container images
   - Deploy CoCo pattern

3. **Phase 3: Lockdown**
   - After cluster is operational and pattern is installed
   - Apply restrictive NSG rules removing Storage access
   - Test that cluster continues to function
   - Workloads run in truly disconnected mode

4. **Phase 4: Document**
   - Create runbook for this hybrid bootstrap approach
   - Note that future node additions may require temporary NSG rule re-enabling

## Lessons Learned

1. **Don't Over-Engineer Security Prematurely**
   - Trying to enforce disconnected NSG rules *during* bootstrap caused all failures
   - OpenShift's architecture assumes cloud platform API access during installation

2. **Read Red Hat Docs Carefully**
   - "Restricted Network" ≠ "Fully Disconnected"
   - Red Hat's restricted network installation is designed for limited internet, not zero internet

3. **Cloud Platforms Have Constraints**
   - Azure's 87KB custom_data limit is a hard constraint
   - Ignition delivery architecture can't be easily changed

4. **IPI vs UPI Trade-offs**
   - IPI: Easier but less control over networking timing
   - UPI: More control but same ignition delivery problem

5. **Focus on Outcomes, Not Methods**
   - Goal: Secure, disconnected OpenShift cluster for CoCo workloads
   - Reality: Bootstrap requires temporary connectivity, runtime can be fully locked down
   - This is acceptable and supported by Red Hat

## Next Steps

1. ✅ Clean up failed resources (COMPLETE)
2. 📝 Update Terraform NSG rules for "restricted network" mode (permissive bootstrap)
3. 🚀 Deploy cluster using Red Hat's recommended approach
4. 🔒 Implement post-install lockdown procedures
5. 📋 Document the full lifecycle for repeatability

## References

- Red Hat OpenShift 4.20 Installing on Azure - Restricted Networks: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/installing_on_azure/index#installing-restricted-networks-azure-installer-provisioned
- Azure VM Custom Data Limits: https://docs.microsoft.com/en-us/azure/virtual-machines/custom-data
- OpenShift Ignition Specification: https://coreos.github.io/ignition/
- Azure Service Endpoints: https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-service-endpoints-overview

---

**Author**: AI Assistant (via Cursor)  
**Date**: 2025-11-13  
**Status**: Active - Awaiting user approval for recommended approach

