# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Validated Pattern** for deploying confidential containers (CoCo) on OpenShift, specifically designed for Azure infrastructure. It implements secure workload deployment using confidential computing with remote attestation and key management through the Trustee Key Broker Service (KBS).

## Architecture

### Current Deployment Model
- **Single cluster** deployment (everything on one cluster)
- **Target model**: Two-cluster separation with trusted zone and workload zone
- **Cloud Support**: Azure only (uses Azure Confidential VMs via peer-pods)
- **OpenShift Version**: 4.16.14+ required

### Key Components
- **Trustee (KBS)**: Key Broker Service for confidential computing secrets
- **OpenShift Sandboxed Containers**: Provides confidential container runtime
- **Peer Pods**: Azure CVM-based confidential VMs
- **Sample Workloads**: Multiple hello-openshift deployments with different security levels

### Directory Structure
- `/ansible/` - Ansible playbooks for Azure resources and cluster setup
- `/charts/` - Helm charts organized by cluster groups:
  - `all/` - Common charts (letsencrypt)
  - `coco-supported/` - Confidential container workloads
  - `hub/` - Hub cluster components (trustee)
- `/common/` - Validated patterns framework (subtree from upstream)
- `/scripts/` - Utility scripts for secret generation
- `/overrides/` - Cloud provider-specific value overrides
- `/values-global.yaml` - Main pattern configuration
- `/values-secret.yaml.template` - Template for sensitive configuration

## Essential Commands

### Installation and Deployment
```bash
# Install the pattern (requires forked repository)
./pattern.sh make install

# Generate required secrets (run once)
sh scripts/gen-secrets.sh

# Show template without installing
./pattern.sh make show

# Load secrets into backend
./pattern.sh make load-secrets
```

### Development and Testing
```bash
# Validate cluster and prerequisites
./pattern.sh make validate-cluster
./pattern.sh make validate-prereq

# Validate values files against schema
./pattern.sh make validate-schema

# Test the pattern
./pattern.sh make test

# Preview all applications
./pattern.sh make preview-all

# Preview specific cluster group
./pattern.sh make preview-<clustergroup>
```

### Secrets Management
```bash
# Configure different secrets backends
./pattern.sh make secrets-backend-vault     # Use Vault + ESO
./pattern.sh make secrets-backend-kubernetes # Use Kubernetes + ESO  
./pattern.sh make secrets-backend-none       # Remove secrets manager

# Legacy vault operations
./pattern.sh make legacy-load-secrets
```

### Maintenance
```bash
# Uninstall the pattern
./pattern.sh make uninstall

# Create token-based kubeconfig
./pattern.sh make token-kubeconfig
```

## Configuration

### Cluster Groups
Change behavior via `global.main.clusterGroupName` in `values-global.yaml`:
- `simple` (default): Single cluster with 3 hello-openshift variants

### Required Secrets
Template in `values-secret.yaml.template`:
- KBS secrets for trustee configuration
- SSH keys for peer-pod access  
- Security policies for confidential containers

### Let's Encrypt Setup
For non-ARO clusters, enable Let's Encrypt in `values-global.yaml`:
```yaml
letsencrypt:
  overrides:
  - name: letsencrypt.enabled
    value: true
```

## Container-based Execution

All commands run through `./pattern.sh` which uses podman to execute utilities in containers. The script:
- Requires podman 4.3.0+ for optimal functionality
- Bind-mounts `$HOME` for file access
- Passes through environment variables for cloud authentication
- Uses `quay.io/hybridcloudpatterns/utility-container` by default

## Git Workflow Requirements

- **Fork-first approach**: Must fork repository as ArgoCD reconciles against your remote fork
- **Conventional commits**: Uses commitlint with `@commitlint/config-conventional`
- **Branch-based deployment**: Pattern deploys from your current checked-out branch
- **Changes require push**: Configuration changes only take effect after commit and push

## Version Support

### Version 3.x (Current)
- OpenShift Sandboxed Containers Operator 1.10.* and above
- Trustee 0.4.*
- OpenShift 4.16.14+ required
- Azure-only support

### Installation Methods
- Azure Red Hat OpenShift (ARO) clusters
- Self-managed OpenShift on Azure (requires Let's Encrypt or custom CA certs)
- Red Hat Demo Platform integration

## Environment Variables for RHDP

When using Red Hat Demo Platform:
```bash
export GUID=
export CLIENT_ID=
export PASSWORD=
export TENANT=
export SUBSCRIPTION=
export RESOURCEGROUP=
```

## Known Limitations

- Additional configuration required for authenticated registry pulls (KATA-4107)
- Azure confidential VMs only
- Single cluster deployment currently (multi-cluster in development)
- Let's Encrypt replaces API certificates (password login required)