# RHDP support

Red Hat demo platform is a system for employees and red hat partners to generate test infrastructure.
The scripts in this directory help users of that platform automate deployments.

## Prerequisites

- `podman` installed and running (used by `pattern.sh` itself)
- Python 3.10+ with the shared script dependencies: `python3 -m pip install -r requirements.txt`
- `cosign` >= 2.0 (used by veritas for Azure image signature verification)
- `yq`, `jq` installed
- OpenShift pull secret (default: `~/pull-secret.json`, override with `PULL_SECRET` — see below)
- An SSH key pair (default: auto-detected, preferring Ed25519 — override with `SSH_PUBLIC_KEY` — see below)
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

The wrapper installs the root `requirements.txt` with its selected Python interpreter, then handles cluster provisioning, secret generation, PCR reference value collection (via veritas), and pattern installation.

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

## Overriding pull secret / SSH key location

By default:

- The OpenShift pull secret is read from `~/pull-secret.json`.
- The SSH public key embedded in `install-config.yaml` is auto-detected,
  preferring `~/.ssh/id_ed25519.pub`, then `~/.ssh/id_ecdsa.pub`, then
  `~/.ssh/id_rsa.pub` (first match wins). Ed25519 is current best practice,
  but existing RSA-only setups keep working without changes.

Both can be overridden if your pull secret or SSH key live somewhere else,
via environment variable:

```shell
export PULL_SECRET=/path/to/pull-secret.json
export SSH_PUBLIC_KEY=/path/to/your/key.pub
bash ./rhdp/wrapper.sh eastasia
```

Since these are plain environment variables, they apply to all three
wrapper scripts without any extra flags. If you run `rhdp/rhdp-cluster-define.py`
directly instead of through a wrapper script, the equivalent CLI flags
`--pull-secret` and `--ssh-public-key` are also available and take
precedence over the environment variables.

If neither an override nor a default/auto-detected file can be found, the
command exits with an error explaining what was checked and how to fix it
(generate a new key with `ssh-keygen -t ed25519`, download a pull secret
from [console.redhat.com](https://console.redhat.com/openshift/downloads),
or set the relevant environment variable).

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
