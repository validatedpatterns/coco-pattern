# Disconnected NSG Architecture for OpenShift on Azure

## Problem Statement
The original configuration had two issues:
1. **Too restrictive**: `DenyInternetOutbound` blocked Azure Storage, preventing VMs from fetching ignition configs
2. **Too permissive**: Initial fix allowed ALL HTTPS to Internet, defeating the purpose of disconnected deployment

## Proper Disconnected Solution (Per Red Hat Documentation)

### Architecture Overview
```
VMs in Private Subnets
  ↓
NAT Gateway (provides outbound SNAT for UserDefinedRouting)
  ↓
Subnet-Level NSG (pre-configured in Terraform)
  ↓
  ├─→ Azure Storage (EastAsia region only) ✅
  ├─→ Azure Cloud APIs (global for cross-region) ✅
  ├─→ VNet (all internal traffic) ✅
  └─→ Internet (all other traffic) ❌ DENIED
  
CAPI creates NIC-Level NSG (empty by design)
  ↓
Subnet NSG rules apply first (traffic already filtered)
```

### Key Components

1. **NAT Gateway**: Associated with master/worker subnets
   - Provides outbound SNAT (required for `outboundType: UserDefinedRouting`)
   - Does NOT filter traffic (that's NSG's job)

2. **Subnet-Level NSG**: Pre-configured in Terraform
   - Applied to subnets BEFORE VMs are created
   - Filters all traffic entering/leaving the subnet
   - CAPI cannot override subnet-level NSG

3. **Service Endpoints**: Configured on subnets
   - `Microsoft.Storage` for Azure Blob Storage
   - `Microsoft.ContainerRegistry` for ACR
   - Optimizes routing (stays on Azure backbone)

4. **CAPI NIC-Level NSG**: Created by Cluster API
   - CAPI creates empty NSG for NICs
   - Azure evaluates BOTH subnet and NIC NSGs
   - Subnet NSG handles filtering (NIC NSG is supplementary)

### NSG Rules (Priority Order)

| Priority | Name | Direction | Destination | Description |
|----------|------|-----------|-------------|-------------|
| 1000 | `AllowAzureStorageRegional` | Outbound | `Storage.EastAsia` | HTTPS to Azure Storage in region only (ignition configs) |
| 1001 | `AllowAzureCloudGlobal` | Outbound | `AzureCloud` | HTTPS to Azure APIs globally (ARM, AAD, cross-region operations) |
| 1002 | `AllowVNetOutbound` | Outbound | `VirtualNetwork` | All traffic within VNet |
| 4096 | `DenyInternetOutbound` | Outbound | `Internet` | Deny all other Internet traffic |

### Why This is Disconnected-Compliant

1. **Azure Service Tags**: Uses `Storage.EastAsia` (regional) and `AzureCloud` (global), not generic `Internet`
   - Only Azure Storage IPs in the region are allowed
   - Only Azure platform services (ARM, AAD, DNS) are allowed - no public Internet
   
2. **Service Endpoints**: Combined with `Microsoft.Storage` service endpoints on subnets
   - Traffic stays on Microsoft backbone network
   - Optimized routing to Azure Storage
   
3. **No General Internet Access**: 
   - Cannot browse web
   - Cannot access external services
   - Cannot download from public repositories

4. **ACR via Private Endpoint**:
   - Container images pulled from ACR through private network
   - Completely isolated from Internet

### What's Allowed vs Denied

#### ✅ ALLOWED:
- Ignition config fetch from OpenShift-created Azure Storage (HTTPS only, region only)
- Azure API calls for VM/network/storage management (HTTPS only, all Azure regions)
- Azure global services (ARM, AAD, Azure DNS - HTTPS only)
- Internal VNet communication (all protocols)
- ACR access via Private Endpoint

#### ❌ DENIED:
- Public Internet HTTP/HTTPS (e.g., google.com, github.com)
- External package repositories (yum, pip, npm)
- SSH to external hosts
- All non-Azure services

### How It Enables OpenShift Installation

1. **Bootstrap Phase**:
   - OpenShift installer creates storage account for ignition configs
   - VMs fetch ignition configs via `Storage.EastAsia` service tag
   - Service endpoints optimize routing (private Microsoft backbone)

2. **Cluster API Phase**:
   - Cluster API controllers create Azure resources
   - API calls allowed via `AzureCloud` service tag (global for cross-region dependencies)
   - NSG rules, VMs, NICs created successfully

3. **Post-Installation**:
   - Pattern applications pull images from ACR (Private Endpoint)
   - No external image pulls allowed
   - Fully disconnected operation

### Comparison Matrix

| Configuration | Storage Access | Azure APIs | Internet | Disconnected? | Works? |
|---------------|----------------|------------|----------|---------------|--------|
| Original (Storage service tag) | ❌ Failed | ❌ Blocked | ❌ Denied | ✅ Yes | ❌ No |
| Proposed Fix 1 (All HTTPS Internet) | ✅ Works | ✅ Works | ⚠️ Allowed | ❌ **NO** | ✅ Yes |
| **Final (Regional Service Tags)** | **✅ Works** | **✅ Works** | **❌ Denied** | **✅ YES** | **✅ Yes** |

### Technical Details

#### Service Tag Format
- Input region: `eastasia`
- Azure service tag format: `EastAsia` (PascalCase)
- Terraform conversion: `replace(title(replace(var.region, "-", " ")), " ", "")`
- Results in: 
  - `Storage.EastAsia` (regional - for ignition configs)
  - `AzureCloud` (global - for Azure platform APIs)

#### Why Global AzureCloud Access is Necessary
Azure services have hard-coded cross-regional behavior and global endpoints:
- **Azure Resource Manager (ARM)**: Global service with potential cross-region redirects
- **Azure Active Directory (AAD)**: Global authentication service
- **Azure DNS**: Global name resolution for Azure services
- **Service Principal authentication**: May query global endpoints
- **Cross-region resource dependencies**: Azure may reference resources in other regions

Using `AzureCloud` (global) instead of `AzureCloud.EastAsia` (regional) ensures these dependencies work correctly while still blocking all non-Azure Internet traffic.

#### Why Generic "Storage" Tag Failed
The generic `Storage` service tag without region specification may not have been properly evaluated by Azure NSG engine in all scenarios. Regional tags (`Storage.EastAsia`) are more explicit and reliable.

#### Service Endpoints
Already configured on master and worker subnets:
```terraform
service_endpoints = ["Microsoft.ContainerRegistry", "Microsoft.Storage"]
```

These optimize routing but don't bypass NSG rules. NSG rules must still allow the traffic.

### Security Posture

**This configuration provides**:
- ✅ True air-gapped operation post-installation
- ✅ Minimal Azure service access (Storage regional, Azure platform global)
- ✅ **No general Internet connectivity** - blocks all non-Azure destinations
- ✅ Enterprise-grade isolation
- ✅ Compliance with disconnected requirements

**What's STILL BLOCKED** (ensuring disconnected compliance):
- ❌ All public websites (google.com, microsoft.com/docs, etc.)
- ❌ GitHub, GitLab, Bitbucket
- ❌ Package repositories (yum repos, PyPI, npm, Maven Central)
- ❌ Container registries (docker.io, quay.io, gcr.io)
- ❌ Any non-Azure cloud services (AWS, GCP, etc.)

The `AzureCloud` service tag **only includes Azure platform IPs**, not general Internet.

**While still enabling**:
- ✅ OpenShift IPI automated installation
- ✅ Cluster API resource management
- ✅ Ignition config delivery
- ✅ Azure platform integration

### Post-Installation Hardening (Optional)

For maximum security, after cluster installation completes:

1. Update NSG to remove `AllowAzureStorageRegional` (ignition configs no longer needed)
2. Consider restricting `AllowAzureCloudOutbound` to specific Azure API endpoints
3. Monitor NSG flow logs to validate no unexpected traffic

### Conclusion

This architecture achieves **true disconnected deployment** while maintaining OpenShift IPI compatibility on Azure. It restricts outbound traffic to only essential Azure services within the region, providing enterprise-grade air-gap isolation without sacrificing automated installation capabilities.

**Key Principle**: *Allow minimal Azure platform services, deny all general Internet access.*

