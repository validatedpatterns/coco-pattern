# Disconnected CoCo Pattern Deployment Guide

This guide provides comprehensive instructions for deploying the CoCo pattern in a disconnected (restricted network) Azure environment.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Stage 1: Infrastructure Provisioning](#stage-1-infrastructure-provisioning)
- [Stage 2: Image Mirroring](#stage-2-image-mirroring)
- [Stage 3: Cluster Installation](#stage-3-cluster-installation)
- [Troubleshooting](#troubleshooting)
- [Cleanup](#cleanup)

## Overview

The disconnected deployment model enables running the CoCo pattern in environments with restricted or no internet access. This is achieved through a two-stage process:

1. **Stage 1 (Developer Workstation)**: Provision Azure infrastructure with Terraform
2. **Stage 2 (Bastion Host)**: Mirror images and install OpenShift cluster in disconnected mode

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Developer Workstation                     │
│                   (Internet Connected)                       │
│                                                              │
│  ┌──────────────┐                                           │
│  │  Terraform   │──────► Provision Infrastructure           │
│  └──────────────┘                                           │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Azure Resources                         │
│                                                              │
│  ┌──────────────────────────────────────────────┐           │
│  │  Bastion Host (Internet via NAT Gateway)     │           │
│  │  - oc-mirror                                 │           │
│  │  - openshift-install                         │           │
│  └──────────────────────────────────────────────┘           │
│                        │                                     │
│                        ▼                                     │
│  ┌──────────────────────────────────────────────┐           │
│  │  Azure Container Registry (ACR)              │           │
│  │  (Private Endpoints Only)                    │           │
│  └──────────────────────────────────────────────┘           │
│                        │                                     │
│                        ▼                                     │
│  ┌──────────────────────────────────────────────┐           │
│  │  OpenShift Cluster (Fully Disconnected)      │           │
│  │  - No internet access                        │           │
│  │  - Images from ACR                           │           │
│  └──────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────┘
```

### Network Isolation

- **Bastion Subnet**: Has outbound internet via NAT Gateway for mirroring
- **OpenShift Master/Worker Subnets**: No internet access (User Defined Routing)
- **ACR**: Accessible only via private endpoints within VNet
- **NSGs**: Enforce traffic restrictions

## Prerequisites

### On Developer Workstation

#### Required Software
- Terraform >= 1.0
- Azure CLI (configured and authenticated)
- SSH client
- Git

#### Required Files
- OpenShift pull secret at `~/pull-secret.json` ([Get from Red Hat](https://console.redhat.com/openshift/downloads))
- SSH key pair at `~/.ssh/id_rsa` (will be generated if missing)

#### RHDP Environment Variables

For RHDP users, set these environment variables:

```bash
export GUID=<your-guid>
export CLIENT_ID=<azure-service-principal-client-id>
export PASSWORD=<azure-service-principal-password>
export TENANT=<azure-tenant-id>
export SUBSCRIPTION=<azure-subscription-id>
export RESOURCEGROUP=<resource-group-name>
```

For non-RHDP Azure users, ensure you're authenticated via Azure CLI:

```bash
az login
az account set --subscription <subscription-id>
```

## Stage 1: Infrastructure Provisioning

Run these steps from your **developer workstation**.

### Step 1.1: Navigate to Project Directory

```bash
cd coco-pattern
```

### Step 1.2: Review Terraform Configuration

Optionally review and customize Terraform variables:

```bash
cd rhdp-isolated/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your preferences
cd ../..
```

### Step 1.3: Provision Infrastructure

Run the provisioning script with your desired Azure region:

```bash
./rhdp-isolated/provision.sh eastus
```

**Available regions**: `eastus`, `westus2`, `centralus`, `northeurope`, `westeurope`, `eastasia`, etc.

This script will:
- Validate environment variables
- Generate SSH key if needed
- Initialize and apply Terraform
- Create:
  - VNet with isolated subnets
  - Azure Container Registry (Premium tier)
  - Bastion VM (RHEL 9)
  - NAT Gateway for bastion internet access
  - Network Security Groups
  - Private endpoints for ACR
- Save connection details to `infrastructure-outputs.env`

**Duration**: 5-10 minutes

### Step 1.4: Configure Bastion Host

Complete the bastion configuration:

```bash
./rhdp-isolated/configure-bastion.sh
```

This script will:
- Wait for cloud-init to complete (tools installed automatically via cloud-init)
- Configure Azure credentials
- Clone pattern repository to bastion (detects your current fork and branch)

**Note**: The bastion host uses RHEL 10 and is configured automatically via cloud-init during first boot. Cloud-init installs:
- OpenShift CLI tools (oc, kubectl, openshift-install, oc-mirror)
- Container tools (podman, skopeo)
- Python packages (jinja2, typer, rich, PyYAML, ansible)
- Formats and mounts 500GB data disk for oc-mirror cache

**Duration**: 5-10 minutes (mostly waiting for cloud-init)

### Step 1.5: Copy Pull Secret to Bastion

```bash
source rhdp-isolated/infrastructure-outputs.env
scp ~/pull-secret.json ${BASTION_USER}@${BASTION_IP}:~/
```

## Stage 2: Image Mirroring

Run these steps **on the bastion host**.

### Step 2.1: SSH to Bastion

```bash
source rhdp-isolated/infrastructure-outputs.env
ssh ${BASTION_USER}@${BASTION_IP}
```

### Step 2.2: Navigate to Pattern Directory

```bash
cd ~/coco-pattern
```

### Step 2.3: Run Image Mirroring

```bash
./rhdp-isolated/bastion/mirror.sh
```

This script will:
- Authenticate to ACR
- Mirror OpenShift 4.20 platform images
- Mirror required operator catalogs:
  - OpenShift Sandboxed Containers (CoCo)
  - OpenShift GitOps
  - Advanced Cluster Management
  - Cert Manager
  - Patterns Operator
- Mirror additional images:
  - Validated Patterns Helm charts
  - Trustee (KBS) images
  - CoCo runtime images
  - Sample application images
- Generate ImageDigestMirrorSet (IDMS) and ImageTagMirrorSet (ITMS)
- Generate CatalogSource definitions

**Duration**: 2-4 hours (depending on network speed)

**Disk space required**: ~60-80GB

### Step 2.4: Verify Mirror Results

After mirroring completes, verify the generated resources:

```bash
ls -lh ~/coco-pattern/cluster-resources/
cat ~/coco-pattern/cluster-resources/mirror-summary.txt
```

You should see files like:
- `idms-oc-mirror.yaml` - Image digest mirror mappings
- `itms-oc-mirror.yaml` - Image tag mirror mappings  
- `cs-redhat-operator-index-v4-20.yaml` - Red Hat operator catalog
- `cs-community-operator-index-v4-20.yaml` - Community operator catalog

## Stage 3: Cluster Installation

Continue on the **bastion host**.

### Step 3.1: Update values-disconnected.yaml

Edit `values-disconnected.yaml` to set your ACR URL:

```bash
vi values-disconnected.yaml
```

Update the `helmRepoUrl` field:

```yaml
global:
  main:
    multiSourceConfig:
      helmRepoUrl: <your-acr-url>.azurecr.io/hybridcloudpatterns
```

Replace `<your-acr-url>` with the value from `$ACR_LOGIN_SERVER`.

Example:
```yaml
helmRepoUrl: acrcocod1a2b3c.azurecr.io/hybridcloudpatterns
```

### Step 3.2: Commit Configuration Changes

The pattern uses GitOps, so changes must be committed:

```bash
git add values-disconnected.yaml
git commit -m "Configure ACR URL for disconnected deployment"
git push origin main
```

**Note**: You may need to configure git credentials or use a personal access token.

### Step 3.3: Run Disconnected Installation

```bash
./rhdp-isolated/bastion/wrapper-disconnected.sh eastus
```

Replace `eastus` with your chosen region (must match Stage 1).

This script will:
- Generate disconnected install-config.yaml with:
  - Private networking configuration (UserDefinedRouting)
  - Image digest sources for mirrored images
  - ACR certificate trust bundle
- Install OpenShift cluster (45-60 minutes)
- Apply IDMS, ITMS, and CatalogSource configurations
- Generate pattern secrets
- Install CoCo pattern using mirrored images

**Duration**: 60-90 minutes

### Step 3.4: Access the Cluster

After installation completes, credentials are displayed:

```bash
export KUBECONFIG=~/coco-pattern/openshift-install-disconnected/auth/kubeconfig
oc get nodes
oc get pods -A
```

Console URL and password:
```bash
oc whoami --show-console
cat ~/coco-pattern/openshift-install-disconnected/auth/kubeadmin-password
```

### Step 3.5: Monitor Pattern Deployment

Watch the pattern applications deploy:

```bash
# Watch ArgoCD applications
oc get applications -A

# Watch GitOps pods
oc get pods -n openshift-gitops

# Watch CoCo operators
oc get csv -n openshift-sandboxed-containers-operator
oc get csv -n trustee-operator-system

# Watch sample workloads
oc get pods -n hello-openshift
```

Full deployment typically takes 20-30 minutes after cluster installation.

## Catalog Source Reference

After mirroring, OpenShift will have these catalog sources available:

| Catalog Name | Contains | Usage |
|--------------|----------|-------|
| `cs-redhat-operator-index-v4-20` | Red Hat certified operators | Most operators (GitOps, ACM, CoCo, Trustee) |
| `cs-community-operator-index-v4-20` | Community operators | Patterns operator |

These names are referenced in `values-disconnected.yaml`.

## Troubleshooting

### Stage 1 Issues

#### Terraform Apply Fails

**Symptom**: Terraform fails during `terraform apply`

**Solutions**:
1. Verify Azure credentials:
   ```bash
   az account show
   ```
2. Check resource group exists:
   ```bash
   az group show --name $RESOURCEGROUP
   ```
3. Review Terraform errors in output
4. Check Azure subscription quotas

#### Cannot SSH to Bastion

**Symptom**: SSH connection times out or refuses

**Solutions**:
1. Verify bastion is running:
   ```bash
   az vm list -g $RESOURCEGROUP --query "[?name contains 'bastion'].[name,provisioningState]" -o table
   ```
2. Check public IP:
   ```bash
   cd rhdp-isolated/terraform
   terraform output bastion_public_ip
   ```
3. Verify NSG rules allow SSH from your IP
4. Wait for cloud-init to complete (5-10 minutes after first boot):
   ```bash
   ssh ${BASTION_USER}@${BASTION_IP} 'cloud-init status --wait'
   ```

### Stage 2 Issues

#### Mirroring Fails - Disk Space

**Symptom**: oc-mirror fails with "no space left on device"

**Solutions**:
1. Check disk space:
   ```bash
   df -h /var/cache/oc-mirror
   ```
2. Clean up old workspace:
   ```bash
   rm -rf /var/cache/oc-mirror/workspace/*
   ```
3. Consider increasing data disk size in Terraform

#### Mirroring Fails - Authentication

**Symptom**: oc-mirror cannot authenticate to registries

**Solutions**:
1. Verify pull secret is valid:
   ```bash
   cat ~/pull-secret.json | jq .
   ```
2. Test ACR login:
   ```bash
   echo $ACR_PASSWORD | podman login $ACR_LOGIN_SERVER -u $ACR_USERNAME --password-stdin
   ```
3. Verify internet connectivity:
   ```bash
   curl -I https://quay.io
   curl -I https://registry.redhat.io
   ```

#### Mirroring Fails - Network

**Symptom**: Connection timeouts to external registries

**Solutions**:
1. Verify NAT gateway is working:
   ```bash
   curl -I https://www.google.com
   ```
2. Check bastion can resolve DNS:
   ```bash
   dig quay.io
   dig registry.redhat.io
   ```
3. Verify NSG allows outbound traffic on bastion subnet

### Stage 3 Issues

#### OpenShift Install Fails - Network

**Symptom**: Installer fails creating bootstrap or nodes

**Solutions**:
1. Verify VNet and subnets exist:
   ```bash
   az network vnet show -g $RESOURCEGROUP -n $VNET_NAME
   ```
2. Check install-config.yaml has correct network settings
3. Review installer logs:
   ```bash
   tail -f ~/coco-pattern/openshift-install-disconnected/.openshift_install.log
   ```

#### OpenShift Install Fails - Images

**Symptom**: Installer cannot pull images

**Solutions**:
1. Verify IDMS was correctly generated:
   ```bash
   cat ~/coco-pattern/cluster-resources/idms-*.yaml
   ```
2. Check imageDigestSources in install-config.yaml
3. Test ACR access from within VNet
4. Verify ACR private endpoint DNS resolution

#### Pattern Install Fails - Catalog Sources

**Symptom**: Operators cannot be installed, catalog sources unavailable

**Solutions**:
1. Check catalog sources:
   ```bash
   oc get catalogsources -n openshift-marketplace
   oc get pods -n openshift-marketplace
   ```
2. Verify ITMS and catalog sources were applied:
   ```bash
   oc get imagetagmirrorsets
   oc describe catalogsource cs-redhat-operator-index-v4-20 -n openshift-marketplace
   ```
3. Check catalog pod logs:
   ```bash
   oc logs -n openshift-marketplace <catalog-pod-name>
   ```

#### Pattern Install Fails - Helm Charts

**Symptom**: Pattern cannot pull Helm charts

**Solutions**:
1. Verify `PATTERN_DISCONNECTED_HOME` was set correctly
2. Check `values-disconnected.yaml` has correct ACR URL
3. Verify Helm charts were mirrored:
   ```bash
   oc-mirror list docker://$ACR_LOGIN_SERVER | grep hybridcloudpatterns
   ```

### Checking CoCo Functionality

After deployment, verify CoCo is working:

```bash
# Check peer-pods controller
oc get pods -n openshift-sandboxed-containers-operator

# Check Trustee
oc get pods -n trustee-operator-system

# Check sample workload
oc get pods -n hello-openshift

# Verify kata runtime classes
oc get runtimeclasses
```

## Cleanup

### Destroy OpenShift Cluster Only

From bastion:
```bash
cd ~/coco-pattern
openshift-install destroy cluster --dir=./openshift-install-disconnected
```

### Destroy All Infrastructure

From developer workstation:
```bash
cd coco-pattern/rhdp-isolated/terraform
terraform destroy
```

**Warning**: This will delete:
- OpenShift cluster
- Bastion host  
- Azure Container Registry (and all mirrored images)
- VNet and networking resources

## Cost Considerations

Approximate Azure costs while running:

| Resource | Cost (USD) |
|----------|------------|
| ACR Premium | ~$0.83/day (~$25/month) |
| Bastion VM (Standard_D4s_v5) | ~$0.24/hour (~$175/month) |
| NAT Gateway | ~$0.045/hour + data transfer |
| 500GB Premium SSD | ~$82/month |
| OpenShift nodes (3x master + 3x worker D8s_v5) | ~$1.90/hour (~$1,370/month) |

**Total**: Approximately **$150-200/month** without OpenShift cluster, **$1,700-2,000/month** with cluster running.

**Cost Optimization Tips**:
- Destroy resources when not in use
- Use smaller VM sizes for testing
- Stop VMs when not needed (though this may cause cluster issues)
- Consider Azure Reserved Instances for long-term deployments

## Additional Resources

- [OpenShift Disconnected Installation](https://docs.openshift.com/container-platform/4.20/installing/disconnected_install/index.html)
- [oc-mirror Documentation](https://docs.openshift.com/container-platform/4.20/installing/disconnected_install/installing-mirroring-disconnected.html)
- [Validated Patterns Disconnected Guide](https://validatedpatterns.io/blog/2024-10-12-disconnected/)
- [CoCo Pattern Documentation](../README.md)

## Support

For issues specific to:
- **CoCo Pattern**: Open issue on [GitHub repository](https://github.com/validatedpatterns/coco-pattern)
- **OpenShift**: Contact Red Hat Support
- **Azure**: Check [Azure documentation](https://docs.microsoft.com/azure)

## Next Steps

After successful installation:
1. Review [CoCo Pattern Usage Guide](USAGE.md)
2. Explore sample workloads in `charts/coco-supported/`
3. Configure Trustee for your security requirements
4. Set up monitoring and logging
5. Plan for updates and maintenance

## Maintenance

### Updating Mirrored Images

To update mirrored images (e.g., for CVEs or new versions):

1. SSH to bastion
2. Update `imageset-config.yaml` if needed
3. Re-run mirror.sh:
   ```bash
   ./rhdp-isolated/bastion/mirror.sh
   ```
4. Apply updated IDMS/ITMS to cluster

### Upgrading OpenShift

Disconnected OpenShift upgrades require:
1. Mirror new OpenShift version
2. Mirror updated operators
3. Update install-config and values files
4. Follow OpenShift upgrade procedures

Consult OpenShift documentation for detailed upgrade procedures.

