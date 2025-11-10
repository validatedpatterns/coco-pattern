# Bastion Scripts - Stage 2

This directory contains scripts that run **on the bastion host** for Stage 2 of the disconnected deployment.

## Prerequisites

Before running these scripts, ensure:
1. Stage 1 provisioning has completed (`provision.sh` and `configure-bastion.sh`)
2. Cloud-init has finished on the bastion (automatic, takes 5-10 minutes after boot)
3. You are SSH'd into the bastion host
4. Pull secret is available at `~/pull-secret.json`
5. Pattern repository has been cloned at `~/coco-pattern` (done by `configure-bastion.sh`)

**Note**: The bastion host uses RHEL 10 and is configured via cloud-init, which automatically:
- Installs OpenShift CLI tools (oc, kubectl, openshift-install, oc-mirror)
- Installs container tools (podman, skopeo)
- Installs Python packages (jinja2, typer, rich, PyYAML, ansible)
- Formats and mounts the 500GB data disk for oc-mirror cache

## Files

### Configuration Files

- **`imageset-config.yaml`**: oc-mirror v2 configuration
  - Defines OpenShift 4.20 platform images
  - Lists required operators (CoCo, GitOps, ACM, etc.)
  - Specifies additional images (Trustee, patterns, samples)

- **`install-config.yaml.j2`**: Jinja2 template for OpenShift installer
  - Configures disconnected networking (UserDefinedRouting)
  - Sets up image digest sources from IDMS
  - Includes ACR certificate trust bundle
  - References Terraform-created network resources

- **`requirements.txt`**: Python dependencies
  - jinja2, typer, rich, PyYAML

### Executable Scripts

- **`mirror.sh`**: Main mirroring script
  - Authenticates to ACR
  - Runs oc-mirror to copy all images
  - Generates IDMS, ITMS, and CatalogSource YAMLs
  - Duration: 2-4 hours
  
- **`wrapper-disconnected.sh <region>`**: Installation orchestrator
  - Generates disconnected install-config
  - Installs OpenShift cluster
  - Applies mirror configurations
  - Installs CoCo pattern
  - Duration: 60-90 minutes

- **`rhdp-cluster-define-disconnected.py <region>`**: Config generator
  - Python script to generate install-config.yaml
  - Parses IDMS to imageDigestSources format
  - Retrieves ACR certificate
  - Called by wrapper-disconnected.sh

## Usage Workflow

### 1. SSH to Bastion

```bash
ssh azureuser@<bastion-ip>
cd ~/coco-pattern
```

### 2. Mirror Images to ACR

```bash
./rhdp-isolated/bastion/mirror.sh
```

This will:
- Download ~60-80GB of container images
- Mirror to your ACR
- Generate cluster configuration files
- Take 2-4 hours

Output location: `~/coco-pattern/cluster-resources/`

### 3. Update Pattern Configuration

Edit `values-disconnected.yaml` with your ACR URL:

```bash
vi values-disconnected.yaml
# Update: helmRepoUrl: <your-acr>.azurecr.io/hybridcloudpatterns
```

Commit changes:
```bash
git add values-disconnected.yaml
git commit -m "Configure ACR for disconnected deployment"
git push
```

### 4. Install OpenShift Cluster

```bash
./rhdp-isolated/bastion/wrapper-disconnected.sh eastus
```

Replace `eastus` with your chosen region.

This will:
- Generate install-config with disconnected settings
- Install OpenShift (45-60 minutes)
- Configure cluster for mirrored images
- Install CoCo pattern

### 5. Access Cluster

```bash
export KUBECONFIG=~/coco-pattern/openshift-install-disconnected/auth/kubeconfig
oc get nodes
oc whoami --show-console
```

## Environment Variables

These should be set by `configure-bastion.sh` in `~/.envrc`:

```bash
GUID                - RHDP environment GUID
CLIENT_ID           - Azure service principal client ID
PASSWORD            - Azure service principal password
TENANT              - Azure tenant ID
SUBSCRIPTION        - Azure subscription ID
RESOURCEGROUP       - Azure resource group name
AZURE_REGION        - Azure region
ACR_LOGIN_SERVER    - ACR URL (e.g., acrcocod123.azurecr.io)
ACR_NAME            - ACR resource name
ACR_USERNAME        - ACR admin username
ACR_PASSWORD        - ACR admin password
VNET_NAME           - VNet name (optional, has default)
MASTER_SUBNET_NAME  - Master subnet name (optional, has default)
WORKER_SUBNET_NAME  - Worker subnet name (optional, has default)
```

## Troubleshooting

### mirror.sh Issues

**"Pull secret not found"**
```bash
scp ~/pull-secret.json azureuser@<bastion-ip>:~/
```

**"No space left on device"**
```bash
df -h /var/cache/oc-mirror
# If full, clean workspace:
rm -rf /var/cache/oc-mirror/workspace/*
```

**"Authentication failed"**
```bash
# Test ACR login
echo $ACR_PASSWORD | podman login $ACR_LOGIN_SERVER -u $ACR_USERNAME --password-stdin

# Test Red Hat registry
podman login registry.redhat.io --authfile=~/pull-secret.json
```

### wrapper-disconnected.sh Issues

**"Cluster resources not found"**
```bash
# Ensure mirror.sh completed successfully
ls -lh ~/coco-pattern/cluster-resources/
# Should see idms-*.yaml, itms-*.yaml, cs-*.yaml files
```

**"OpenShift installation failed"**
```bash
# Check installer logs
tail -f ~/coco-pattern/openshift-install-disconnected/.openshift_install.log

# Verify install-config
cat ~/coco-pattern/openshift-install-disconnected/install-config.yaml
```

**"Pattern installation failed"**
```bash
# Check catalog sources
export KUBECONFIG=~/coco-pattern/openshift-install-disconnected/auth/kubeconfig
oc get catalogsources -n openshift-marketplace
oc get pods -n openshift-marketplace

# Verify IDMS/ITMS
oc get imagedigestmirrorsets
oc get imagetagmirrorsets
```

## Files Generated During Process

After mirroring:
```
~/coco-pattern/cluster-resources/
├── idms-oc-mirror.yaml              # Image digest mappings
├── itms-oc-mirror.yaml              # Image tag mappings
├── cs-redhat-operator-index-v4-20.yaml     # Red Hat catalog
├── cs-community-operator-index-v4-20.yaml  # Community catalog
└── mirror-summary.txt               # Summary of mirroring
```

After installation:
```
~/coco-pattern/openshift-install-disconnected/
├── auth/
│   ├── kubeconfig                   # Cluster credentials
│   └── kubeadmin-password           # Console password
├── install-config.yaml              # Used install config
└── .openshift_install.log           # Installation logs
```

## Additional Notes

- **Mirroring is idempotent**: Re-running mirror.sh will only update changed images
- **Installation is NOT idempotent**: Failed installations should be cleaned up before retry
- **Network isolation**: OpenShift nodes have NO internet access, only ACR via private endpoint
- **Updates**: To update mirrored content, re-run mirror.sh with updated imageset-config.yaml

## See Also

- [Main Disconnected Guide](../../docs/DISCONNECTED.md)
- [Stage 1 README](../README.md)
- [Terraform Infrastructure](../terraform/README.md)

