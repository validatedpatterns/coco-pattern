# Disconnected CoCo Pattern - Quick Start

A condensed guide for experienced users. See [docs/DISCONNECTED.md](../docs/DISCONNECTED.md) for full documentation.

## Prerequisites

- Azure credentials (RHDP environment variables or Azure CLI)
- Terraform >= 1.0
- OpenShift pull secret at `~/pull-secret.json`
- SSH key at `~/.ssh/id_rsa` (or will be generated)

## Stage 1: Provision (Developer Workstation)

```bash
# Set environment variables (RHDP users)
export GUID=xxxxx
export CLIENT_ID=xxxxx
export PASSWORD=xxxxx
export TENANT=xxxxx
export SUBSCRIPTION=xxxxx
export RESOURCEGROUP=xxxxx

# Provision infrastructure (includes RHEL 10 bastion with cloud-init)
./rhdp-isolated/provision.sh eastus

# Configure bastion (waits for cloud-init, sets up env)
./rhdp-isolated/configure-bastion.sh

# Copy pull secret
source rhdp-isolated/infrastructure-outputs.env
scp ~/pull-secret.json ${BASTION_USER}@${BASTION_IP}:~/
```

## Stage 2: Mirror & Install (Bastion Host)

```bash
# SSH to bastion
ssh ${BASTION_USER}@${BASTION_IP}
cd ~/coco-pattern

# Mirror images (2-4 hours)
./rhdp-isolated/bastion/mirror.sh

# Update values-disconnected.yaml with ACR URL
vi values-disconnected.yaml
# Change: helmRepoUrl: <your-acr>.azurecr.io/hybridcloudpatterns

# Commit changes
git add values-disconnected.yaml
git commit -m "Configure ACR for disconnected"
git push

# Install cluster (60-90 minutes)
./rhdp-isolated/bastion/wrapper-disconnected.sh eastus

# Access cluster
export KUBECONFIG=~/coco-pattern/openshift-install-disconnected/auth/kubeconfig
oc get nodes
```

## Key Outputs

**Infrastructure**: `rhdp-isolated/infrastructure-outputs.env`
**Mirror Results**: `~/coco-pattern/cluster-resources/`
**Cluster Credentials**: `~/coco-pattern/openshift-install-disconnected/auth/`

## Cleanup

```bash
# From workstation
cd rhdp-isolated/terraform
terraform destroy
```

## Troubleshooting Quick Reference

| Issue | Solution |
|-------|----------|
| SSH to bastion fails | Wait for VM to fully boot, check NSG rules |
| Mirror fails (disk space) | `df -h /var/cache/oc-mirror`, clean workspace if needed |
| Mirror fails (auth) | Verify pull secret, test `podman login` |
| Install fails (network) | Check VNet exists, verify install-config network settings |
| Install fails (images) | Verify IDMS generated, check imageDigestSources |
| Pattern fails (catalogs) | Check `oc get catalogsources -n openshift-marketplace` |

## Architecture

```
Developer Workstation → Terraform → Azure Infrastructure
                                    ├─ Bastion (internet via NAT)
                                    ├─ ACR (private endpoints)
                                    └─ OpenShift (fully disconnected)
```

## Costs

~$150-200/month for infrastructure only
~$1,700-2,000/month with OpenShift cluster running

Destroy when not in use!

## Full Documentation

- [Complete Guide](../docs/DISCONNECTED.md)
- [Terraform README](terraform/README.md)
- [Bastion Scripts README](bastion/README.md)

