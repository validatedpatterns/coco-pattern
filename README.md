# coco-pattern

Validated pattern for deploying confidential containers on OpenShift using the [Validated Patterns](https://validatedpatterns.io/) framework.

Confidential containers use hardware-backed Trusted Execution Environments (TEEs) to isolate workloads from cluster and hypervisor administrators. This pattern deploys and configures the Red Hat CoCo stack — including the sandboxed containers operator, Trustee (Key Broker Service), and peer-pod infrastructure — on Azure.

## Topologies

The pattern provides two deployment topologies:

1. **Single cluster** (`simple` clusterGroup) — deploys all components (Trustee, Vault, ACM, sandboxed containers, workloads) in one cluster. This breaks the RACI separation expected in a remote attestation architecture but simplifies testing and demonstrations.

2. **Multi-cluster** (`trusted-hub` + `spoke` clusterGroups) — separates the trusted zone from the untrusted workload zone:
   - **Hub** (`trusted-hub`): Runs Trustee (KBS + attestation service), HashiCorp Vault, ACM, and cert-manager. This cluster is the trust anchor.
   - **Spoke** (`spoke`): Runs the sandboxed containers operator and confidential workloads. The spoke is imported into ACM and managed from the hub.

The topology is controlled by the `main.clusterGroupName` field in `values-global.yaml`.

Currently supports Azure via peer-pods. Peer-pods provision confidential VMs (`Standard_DCas_v5` family) directly on the Azure hypervisor rather than nesting VMs inside worker nodes.

## Current version (4.*)

Breaking change from v3. This is the first version using GA (Generally Available) releases of the CoCo stack:

- **OpenShift Sandboxed Containers 1.11+** (requires OCP 4.17+)
- **Red Hat Build of Trustee 1.0** (first GA release; all prior versions were Technology Preview)
- External chart repositories for [Trustee](https://github.com/validatedpatterns/trustee-chart), [sandboxed-containers](https://github.com/validatedpatterns/sandboxed-containers-chart), and [sandboxed-policies](https://github.com/validatedpatterns/sandboxed-policies-chart)
- Self-signed certificates via cert-manager (Let's Encrypt no longer required)
- Multi-cluster support via ACM

### Previous versions

All previous versions used pre-GA (Technology Preview) releases of Trustee:

| Version | Trustee | OSC | Min OCP |
|---------|---------|-----|---------|
| **3.*** | 0.4.* (Tech Preview) | 1.10.* | 4.16+ |
| **2.*** | 0.3.* (Tech Preview) | 1.9.* | 4.16+ |
| **1.0.0** | 0.2.0 (Tech Preview) | 1.8.1 | 4.16+ |

## Setup

### Prerequisites

- OpenShift 4.17+ cluster on Azure (self-managed via `openshift-install` or ARO)
- Azure `Standard_DCas_v5` VM quota in your target region (these are confidential computing VMs and are not available in all regions). See the note below for more details.
- Azure DNS hosting the cluster's DNS zone
- Tools on your workstation: `podman`, `yq`, `jq`, `skopeo`
- OpenShift pull secret saved at `~/pull-secret.json` (download from [console.redhat.com](https://console.redhat.com/openshift/downloads))
- Fork the repository — ArgoCD reconciles cluster state against your fork, so changes must be pushed to your remote

### Secrets and PCR setup

These scripts generate the cryptographic material and attestation measurements needed by Trustee and the peer-pod VMs. Run them once before your first deployment.

1. `bash scripts/gen-secrets.sh` — generates KBS key pairs, attestation policy seeds, and copies `values-secret.yaml.template` to `~/values-secret-coco-pattern.yaml`
2. `bash scripts/get-pcr.sh` — retrieves PCR measurements from the peer-pod VM image and stores them at `~/.coco-pattern/measurements.json` (requires `podman`, `skopeo`, and `~/pull-secret.json`)
3. Review and customise `~/values-secret-coco-pattern.yaml` — this file is loaded into Vault and provides secrets to the pattern

> **Note:** `gen-secrets.sh` will not overwrite existing secrets. Delete `~/.coco-pattern/` if you need to regenerate.

### Single cluster deployment

1. Set `main.clusterGroupName: simple` in `values-global.yaml`
2. Ensure your Azure configuration is populated in `values-global.yaml` (see `global.azure.*` fields)
3. `./pattern.sh make install`
4. Wait for the cluster to reboot all nodes (the sandboxed containers operator triggers a MachineConfig update). Monitor progress in the ArgoCD UI.

### Multi-cluster deployment

1. Set `main.clusterGroupName: trusted-hub` in `values-global.yaml`
2. Deploy the hub cluster: `./pattern.sh make install`
3. Wait for ACM (`MultiClusterHub`) to reach `Running` state on the hub
4. Provision a second OpenShift 4.17+ cluster on Azure for the spoke
5. Import the spoke into ACM with label `clusterGroup=spoke`
   (see [importing a cluster](https://validatedpatterns.io/learn/importing-a-cluster/))
6. ACM will automatically deploy the `spoke` clusterGroup applications (sandboxed containers, workloads) to the imported cluster

## Sample applications

Two sample applications are deployed on the cluster running confidential workloads (the single cluster in `simple` mode, or the spoke in multi-cluster mode):

- **hello-openshift**: Three pods demonstrating CoCo security boundaries:
  - `standard` — a regular Kubernetes pod (no confidential computing)
  - `secure` — a confidential container with a strict policy; `oc exec` is denied even for `kubeadmin`
  - `insecure-policy` — a confidential container with a relaxed policy allowing `oc exec` (useful for testing the Confidential Data Hub)

  Each confidential pod runs on its own `Standard_DC2as_v5` Azure VM (visible in the Azure portal). Pods use `runtimeClassName: kata-remote`.

- **kbs-access**: A web service that retrieves and presents secrets obtained from the Trustee Key Broker Service (KBS) via the Confidential Data Hub (CDH). Useful for verifying end-to-end attestation and secret delivery in locked-down environments.

## Confidential computing virtual machine availability on Microsoft Azure

Confidential computing VM availability on Azure varies by region. Not all regions offer the required VM families, and available sizes differ between regions. Before deploying, verify the following:

1. **Check regional availability.** Confirm that your target Azure region supports confidential computing VMs. Microsoft's [products available by region](https://azure.microsoft.com/en-us/explore/global-infrastructure/products-by-region/) page lists which services and VM families are offered in each region.

2. **Check your subscription quota.** Even in supported regions, your subscription may have zero default quota for confidential VM sizes. Go to **Azure Portal > Subscriptions > Usage + quotas** and filter for the DCas/DCads/ECas/ECads families. Request a quota increase if needed.

3. **Select a VM size.** The pattern defaults to `Standard_DC2as_v5` but supports a configurable list of sizes. The following VM families are relevant for confidential containers on Azure:

| VM Family | CPU | Architecture | Notes |
|-----------|-----|--------------|-------|
| `Standard_DC2as_v5` | AMD SEV-SNP | AMD EPYC (Genoa) | Default for this pattern. Smallest CoCo-capable size. |
| `Standard_DC4as_v5` | AMD SEV-SNP | AMD EPYC (Genoa) | More vCPUs/memory for larger workloads. |
| `Standard_DC2ads_v5` | AMD SEV-SNP | AMD EPYC (Genoa) | Same as DC2as_v5 with a local temp disk. |
| `Standard_DC2es_v5` | Intel TDX | Intel Xeon (Sapphire Rapids) | Intel-based confidential VMs. Regional availability is more limited than AMD. |

The available sizes can be configured via the `global.coco.azure.VMFlavours` field in `values-global.yaml` and the sandbox-policies chart overrides. The default VM flavour is set in `global.coco.azure.defaultVMFlavour`.

### RHDP deployment (Red Hat Demo Platform)

For Red Hat associates and partners, the pattern includes wrapper scripts that automate cluster provisioning and deployment using RHDP Azure Open Environments.

Required environment variables (provided by your RHDP environment):

```shell
export GUID=
export CLIENT_ID=
export PASSWORD=
export TENANT=
export SUBSCRIPTION=
export RESOURCEGROUP=
```

Deployment commands:

- Single cluster: `bash rhdp/wrapper.sh <azure-region>` (e.g. `bash rhdp/wrapper.sh eastasia`)
- Multi-cluster: `bash rhdp/wrapper-multicluster.sh <azure-region>`

The wrapper scripts handle cluster provisioning via `openshift-install`, secret generation, PCR retrieval, and pattern installation.
