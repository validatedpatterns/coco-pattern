# Disconnected CoCo Pattern Deployment

This directory contains scripts and configurations for deploying the CoCo pattern in a disconnected/restricted Azure environment.

## Architecture Overview

```
Developer Workstation (Stage 1)
    |
    | Terraform
    v
Azure Infrastructure:
  - Bastion Host (has internet via NAT)
  - Azure Container Registry (ACR) with private endpoints
  - Private VNet for OpenShift
    |
    | Stage 2 (from Bastion)
    v
  - Mirror images to ACR (via oc-mirror)
  - Install OpenShift in private network
  - Deploy CoCo pattern using mirrored images
```

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

8. Install the disconnected cluster:
   ```bash
   ./rhdp-isolated/bastion/wrapper-disconnected.sh eastus
   ```
   
   This will:
   - Generate disconnected install-config
   - Install OpenShift cluster in private network
   - Apply mirror configuration
   - Install CoCo pattern with mirrored images

## Directory Structure

```
rhdp-isolated/
├── README.md                      # This file
├── provision.sh                   # Stage 1: Provision infrastructure
├── configure-bastion.sh           # Stage 1: Configure bastion host
├── terraform/                     # Terraform configurations
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── versions.tf
└── bastion/                       # Stage 2: Scripts for bastion
    ├── imageset-config.yaml       # oc-mirror configuration
    ├── mirror.sh                  # Mirror images to ACR
    ├── install-config.yaml.j2     # Disconnected install config template
    ├── wrapper-disconnected.sh    # Main installation script
    └── rhdp-cluster-define-disconnected.py  # Config generator
```

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

## Network Design

The infrastructure uses a restricted network model:

- **Bastion Subnet**: Has internet via NAT gateway for mirroring
- **OpenShift Subnets**: No direct internet access
- **ACR**: Accessible via private endpoints only
- **NSGs**: Enforce traffic restrictions

This ensures the OpenShift cluster operates in a fully disconnected mode while allowing the bastion to perform necessary mirroring operations.

## Cost Considerations

Key Azure resources and approximate costs:

- ACR Premium: ~$0.833/day
- Bastion VM (Standard_D4s_v5): ~$0.24/hour
- NAT Gateway: ~$0.045/hour + data transfer
- 500GB Premium SSD: ~$81.92/month

Estimated total: ~$150-200/month while running.

Remember to destroy resources when not in use!

