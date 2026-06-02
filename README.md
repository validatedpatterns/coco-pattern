# coco-pattern

Validated pattern for deploying confidential containers on OpenShift using the [Validated Patterns](https://validatedpatterns.io/) framework.

Confidential containers use hardware-backed Trusted Execution Environments (TEEs) to isolate workloads from cluster and hypervisor administrators. This pattern deploys and configures the Red Hat CoCo stack — including the sandboxed containers operator, Trustee (Key Broker Service) operator, and Kata infrastructure — on Azure cloud instances and bare metal.

## Topologies

The pattern provides four deployment topologies:

1. **Single cluster** (`simple` clusterGroup) — deploys all components (Trustee, Vault, ACM, sandboxed containers, workloads) in one cluster on Azure. This breaks the RACI separation expected in a remote attestation architecture but simplifies testing and demonstrations.

2. **Multi-cluster** (`trusted-hub` + `spoke` clusterGroups) — separates the trusted zone from the untrusted workload zone:
   - **Hub** (`trusted-hub`): Runs Trustee (KBS + attestation service), HashiCorp Vault, ACM, and cert-manager. This cluster is the trust anchor.
   - **Spoke** (`spoke`): Runs the sandboxed containers operator and confidential workloads. The spoke is imported into ACM and managed from the hub.

3. **Bare metal** (`baremetal` clusterGroup) — deploys all components on bare metal hardware with Intel TDX or AMD SEV-SNP support. NFD (Node Feature Discovery) auto-detects the CPU architecture and configures the appropriate runtime. Supports SNO (Single Node OpenShift) and multi-node clusters.

4. **Bare metal with GPU** (`baremetal-gpu` clusterGroup) — extends the bare metal topology with NVIDIA H100 confidential GPU support. Adds the NVIDIA GPU Operator, IOMMU kernel configuration, and a sample CUDA workload for CC GPU verification. Requires NVIDIA H100 GPUs with confidential computing firmware.

The topology is controlled by the `main.clusterGroupName` field in `values-global.yaml`.

Azure deployments use peer-pods, which provision confidential VMs (`Standard_DCas_v5` family) directly on the Azure hypervisor. Bare metal deployments use layered images and hardware TEE features directly.

## Current version (5.*)

Breaking change from v4. Uses GA releases of the CoCo stack with Kyverno-based initdata injection.

- **5.0** — Kyverno-based `cc_init_data` injection (replaces MutatingAdmissionPolicy), OSC 1.12 / Trustee 1.1 GA, external chart repositories, self-signed certificates via cert-manager, multi-cluster support via ACM. Requires OCP 4.19.28+.
- **5.1** — Bare metal support for Intel TDX and AMD SEV-SNP via NFD auto-detection. Currently tested on SNO (Single Node OpenShift) configurations only.
- **5.2** — NVIDIA H100 confidential GPU support for bare metal (`baremetal-gpu` clusterGroup). Adds GPU Operator, IOMMU configuration, CC Manager, and sample CUDA workload.
- **5.3** — DRY refactor of trustee and kyverno overrides, Kyverno CRD label fix, pattern infrastructure update.
- **5.4** — Firmware reference values workflow for bare metal attestation via veritas. Adds `collect-firmware-refvals.sh`, RVPS integration, and hardened attestation policy (trustee-chart v0.5.0).
- **5.5** — Trustee-chart v0.7.0 (td_attributes.debug path fix). Unified reference value collection for Azure and bare metal via veritas container.
- **5.6** — Documentation update, sandboxed-policies v0.2.0 (Azure-conditional peer-pods).

### Previous versions

| Version | Trustee | OSC | Min OCP | Notes |
|---------|---------|-----|---------|-------|
| **4.*** | 1.1 (GA) | 1.12 | 4.19.28+ | First GA release; MutatingAdmissionPolicy-based initdata |
| **3.*** | 0.4.* (Tech Preview) | 1.10.* | 4.16+ | |
| **2.*** | 0.3.* (Tech Preview) | 1.9.* | 4.16+ | |
| **1.0.0** | 0.2.0 (Tech Preview) | 1.8.1 | 4.16+ | |

## Setup

### Prerequisites

**Azure deployments:**

- OpenShift 4.19.28+ cluster on Azure (self-managed via `openshift-install` or ARO)
- Azure `Standard_DCas_v5` VM quota in your target region (these are confidential computing VMs and are not available in all regions). See the note below for more details.
- Azure DNS hosting the cluster's DNS zone

**Bare metal deployments:**

- OpenShift 4.19.28+ cluster on bare metal with Intel TDX or AMD SEV-SNP hardware
- BIOS/firmware configured to enable TDX or SEV-SNP
- Available block devices for LVMS storage (auto-discovered)
- For Intel TDX: an Intel PCS API key from [api.portal.trustedservices.intel.com](https://api.portal.trustedservices.intel.com/)

**Common:**

- Tools on your workstation: `podman`, `yq`, `jq`, `skopeo`
- OpenShift pull secret saved at `~/pull-secret.json` (download from [console.redhat.com](https://console.redhat.com/openshift/downloads))
- Fork the repository — ArgoCD reconciles cluster state against your fork, so changes must be pushed to your remote

### Secrets and reference value setup

These scripts generate the cryptographic material and attestation reference values needed by Trustee. Run them once before your first deployment.

1. `bash scripts/gen-secrets.sh` — generates KBS key pairs, PCCS certificates/tokens (for bare metal), and copies `values-secret.yaml.template` to `~/values-secret-coco-pattern.yaml`
2. Collect attestation reference values (requires `podman`, `yq`, `jq`, and `~/pull-secret.json`):
   - **Azure:** `make collect-azure-refvals` — pulls PCR measurements from the dm-verity image via veritas. Saves to `~/.coco-pattern/measurements.json`.
   - **Bare metal:** `make collect-firmware-refvals` — computes firmware measurements from OCP release artifacts via veritas. Saves to `~/.coco-pattern/firmware-reference-values.json`. For bare metal, also uncomment the `firmwareReferenceValues` section in `~/values-secret-coco-pattern.yaml`.
   - See [docs/firmware-reference-values.md](docs/firmware-reference-values.md) for detailed workflow and options.
3. Review and customise `~/values-secret-coco-pattern.yaml` — this file is loaded into Vault and provides secrets to the pattern. For bare metal, uncomment the PCCS secrets section and provide your Intel PCS API key.

> **Note:** `gen-secrets.sh` will not overwrite existing secrets. Delete `~/.coco-pattern/` if you need to regenerate.

### Single cluster deployment (Azure)

1. Set `main.clusterGroupName: simple` in `values-global.yaml`
2. Ensure your Azure configuration is populated in `values-global.yaml` (see `global.azure.*` fields)
3. `./pattern.sh make install`
4. Wait for the cluster to reboot all nodes (the sandboxed containers operator triggers a MachineConfig update). Monitor progress in the ArgoCD UI.

### Multi-cluster deployment (Azure)

1. Set `main.clusterGroupName: trusted-hub` in `values-global.yaml`
2. Deploy the hub cluster: `./pattern.sh make install`
3. Wait for ACM (`MultiClusterHub`) to reach `Running` state on the hub
4. Provision a second OpenShift 4.19.28+ cluster on Azure for the spoke
5. Import the spoke into ACM with label `clusterGroup=spoke`
   (see [importing a cluster](https://validatedpatterns.io/learn/importing-a-cluster/))
6. ACM will automatically deploy the `spoke` clusterGroup applications (sandboxed containers, workloads) to the imported cluster

### Bare metal deployment

1. Set `main.clusterGroupName: baremetal` in `values-global.yaml`
2. Run `bash scripts/gen-secrets.sh` to generate KBS keys and PCCS secrets
3. For Intel TDX: uncomment the PCCS secrets in `~/values-secret-coco-pattern.yaml` and provide your Intel PCS API key
4. `./pattern.sh make install`
5. Wait for the cluster to reboot nodes (MachineConfig updates for TDX kernel parameters and vsock)

> **Note:** Bare metal support is currently tested on SNO (Single Node OpenShift) configurations. Multi-node bare metal clusters are expected to work but have not been validated yet.

The system auto-detects your hardware:

- **NFD** discovers Intel TDX or AMD SEV-SNP capabilities and labels nodes
- **LVMS** auto-discovers available block devices for storage
- **RuntimeClass** `kata-cc` is created automatically pointing to the correct handler (`kata-tdx` or `kata-snp`)
- Both `kata-tdx` and `kata-snp` RuntimeClasses are deployed; only the one matching your hardware has schedulable nodes
- MachineConfigs are deployed for both `master` and `worker` roles (safe on SNO where only master exists)
- PCCS and QGS services deploy unconditionally; DaemonSets only schedule on Intel nodes via NFD labels

Optional: pin PCCS to a specific node with `bash scripts/get-pccs-node.sh` and set `baremetal.pccs.nodeSelector` in the baremetal chart values.

### Bare metal GPU deployment

1. Set `main.clusterGroupName: baremetal-gpu` in `values-global.yaml`
2. Run `bash scripts/gen-secrets.sh` to generate KBS keys and PCCS secrets
3. For Intel TDX: uncomment the PCCS secrets in `~/values-secret-coco-pattern.yaml` and provide your Intel PCS API key
4. `./pattern.sh make install`
5. Wait for the cluster to reboot nodes (MachineConfig updates for TDX/SEV-SNP kernel parameters, vsock, and IOMMU)
6. Approve the GPU Operator install plan when it appears (uses `installPlanApproval: Manual`)

> **Note:** The `baremetal-gpu` topology deploys IOMMU MachineConfig on all nodes and will trigger reboots. For clusters without GPUs, use the `baremetal` topology instead. The GPU workload deployment will remain Pending on non-GPU systems but is otherwise harmless.

## Sample applications

Two sample applications are deployed on the cluster running confidential workloads (the single cluster in `simple` mode, or the spoke in multi-cluster mode):

- **hello-openshift**: Three pods demonstrating CoCo security boundaries:
  - `standard` — a regular Kubernetes pod (no confidential computing)
  - `secure` — a confidential container with a strict policy; `oc exec` is denied even for `kubeadmin`
  - `insecure-policy` — a confidential container with a relaxed policy allowing `oc exec` (useful for testing the Confidential Data Hub)

  On Azure, each confidential pod runs on its own `Standard_DC2as_v5` Azure VM (visible in the Azure portal) using `runtimeClassName: kata-remote`. On bare metal, pods use `runtimeClassName: kata-cc` and run directly on the underlying TDX or SEV-SNP hardware.

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

The wrapper scripts handle cluster provisioning via `openshift-install`, secret generation, reference value collection, and pattern installation.
