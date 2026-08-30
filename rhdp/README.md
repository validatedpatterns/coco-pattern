# RHDP support

Red Hat demo platform is a system for employees and red hat partners to generate test infrastructure.
The scripts in this directory help users of that platform automate deployments.

## Prerequisites

- `podman` installed and running (used for reference value collection)
- `yq`, `jq` installed
- OpenShift pull secret at `~/pull-secret.json`
- SSH key at `~/.ssh/id_rsa` (RSA)
- RHDP environment variables loaded (see below)

## Environment variables

Provided by your RHDP Azure Open Environment:

```shell
export GUID=
export CLIENT_ID=
export PASSWORD=
export TENANT=
export SUBSCRIPTION=
export RESOURCEGROUP=
```

## To deploy

1. Stand up the 'Azure Subscription Based Blank Open Environment'
2. Download the credentials
3. Load the credentials into your environment (e.g. using `direnv`)
4. Launch the wrapper script from the repository root directory:

### Single Cluster Deployment

   1. Set `main.clusterGroupName: simple` in `values-global.yaml`
   2. `bash ./rhdp/wrapper.sh eastasia`
   3. The wrapper script **requires** an azure region code. This code SHOULD be the same as what was selected in RHDP.
   4. Optionally use `--prefix` for custom cluster naming: `bash ./rhdp/wrapper.sh --prefix dev1 eastasia`

The wrapper handles: cluster provisioning, secret generation, PCR reference value collection (via veritas), and pattern installation.

### Multi-Cluster Deployment (Hub and Spoke)

   1. Set `main.clusterGroupName: trusted-hub` in `values-global.yaml`
   2. `bash ./rhdp/wrapper-multicluster.sh eastasia`
   3. This creates two clusters: `coco-hub` and `coco-spoke` in the same region
   4. The pattern is deployed on the hub cluster; the spoke is imported into ACM
   5. Hub cluster kubeconfig: `./openshift-install-hub/auth/kubeconfig`
   6. Spoke cluster kubeconfig: `./openshift-install-spoke/auth/kubeconfig`

### Cluster Only (no pattern install)

   1. `bash ./rhdp/wrapper-cluster-only.sh eastasia`
   2. Provisions the cluster without installing secrets or the pattern

## Re-running against an existing install directory

All three wrapper scripts (and `rhdp/rhdp-cluster-define.py` directly) refuse
to touch an install directory (e.g. `openshift-install`,
`openshift-install-hub`) that already has cluster state (`metadata.json`)
from a previous run. This prevents accidentally wiping the local record of a
still-live cluster and silently replacing it with a new one.

If you see an error about existing cluster install state, you have two
options:

1. **Destroy the existing cluster's cloud resources yourself first**, then
   re-run the wrapper normally:

   ```shell
   openshift-install destroy cluster --dir=./openshift-install
   ```

2. **Pass `--recreate`** if you've already confirmed the cloud resources are
   gone (or were never fully created):

   ```shell
   bash ./rhdp/wrapper.sh --recreate eastasia
   ```

   **`--recreate` does NOT call `openshift-install destroy cluster` for
   you.** It only wipes the local install directory so a fresh install can
   proceed. If the previous cluster's cloud resources are still live, they
   will be orphaned (left running in Azure, unmanaged) — verify and clean
   those up manually via the Azure portal/CLI if needed.
