# Disconnected (Airgap) Deployment Guide

Deploy the CoCo validated pattern on a disconnected OpenShift cluster using mirrored content.

## Prerequisites

- OpenShift 4.21+ cluster installed (SNO or HA) with no internet access
- Jump host with access to both the internet and the disconnected network
- Quay registry on the disconnected network (e.g. `quay.example.com:443`)
- `oc`, `oc-mirror`, `openshift-install`, `python3`, `git` on the jump host
- `labctl` for APAC lab environments (optional)

## Architecture

```
Internet ──► Jump Host ──► Disconnected Network
                │                    │
          quay.io (source)    quay-mirror (dest)
          github.com          git-http-server:8080
                              OCP 4.21 cluster
```

**Content flows:**
1. `oc-mirror` mirrors OCP release + operator catalogs + container images to Quay
2. `airgap-post-install.sh` mirrors OCI Helm charts (oc-mirror can't handle these)
3. `git-http-server.py` serves pattern git repos over smart HTTP (go-git requires this)
4. Pattern operator clones from git server, ArgoCD pulls Helm charts from Quay

## Step-by-Step Deployment

### 1. Mirror content to Quay

```bash
# From the jump host (internet access required)
cd ~/coco-pattern

# Mirror OCP release, operators, and container images
make airgap-mirror \
  MIRROR_REGISTRY=quay.example.com:443/mirror \
  IMAGESET_CONFIG=airgap/imageset-config.yaml
```

**What gets mirrored:**
- OCP 4.21.24 release images
- Red Hat operators: gitops, sandboxed-containers, trustee, cert-manager, ACM, LVM, CNV, NFD, intel-device-plugins
- Certified operators: gpu-operator
- Community operators: patterns-operator
- Container images: Vault, Kyverno, UBI, VP utilities

**Known limitation:** `oc-mirror --v2` cannot mirror OCI Helm chart artifacts via `additionalImages`. The post-install script handles these separately.

**Known limitation:** `oc-mirror --v2` fails on images published as OCI image indexes (`application/vnd.oci.image.index.v1+json`) with "Manifest list must be converted" error. Currently only affects `patterns-operator`. See [patterns-operator#774](https://github.com/validatedpatterns/patterns-operator/issues/774). Workaround: deploy operator manually (automated in bootstrap script).

### 2. Install OpenShift

```bash
# Generate install configs
labctl generate --node node-02 --xlsx "lab-details.xlsx"

# Build ISO (embeds mirror config + CA cert)
cd ~/node-02-airgap-output
mkdir -p BUILD_DIR && cp install-config.yaml agent-config.yaml BUILD_DIR/
cd BUILD_DIR
openshift-install agent create image --dir .

# Mount ISO and boot
labctl idrac mount-iso --node node-02 --xlsx "lab-details.xlsx" \
  --iso-url "http://jump-host/~user/node-02.iso"

# Monitor install (~35 min)
openshift-install agent wait-for install-complete --dir .
```

**Important:** Agent-based install ISOs expire after ~24 hours (embedded certificates). Always rebuild before installing.

### 3. Apply mirror resources

```bash
# Apply IDMS, ITMS, and CatalogSources from oc-mirror workspace
labctl apply-mirror-resources \
  --dir ~/oc-mirror-workspace/working-dir/cluster-resources \
  --kubeconfig $KUBECONFIG
```

### 4. Run post-install bootstrap

```bash
export KUBECONFIG=~/node-02-airgap-output/BUILD_DIR/auth/kubeconfig
export MIRROR_REGISTRY=quay.example.com:443/mirror

# Optional: enable routingViaHost for lab networks where the default
# gateway can't route to the jump host subnet
export ENABLE_ROUTINGVIAHOST=true  # APAC lab only

cd ~/coco-pattern
make airgap-post-install
```

**What the bootstrap does (11 steps):**

| Step | Action |
|------|--------|
| 1 | Validate prerequisites (oc, git, KUBECONFIG, MIRROR_REGISTRY) |
| 2 | Disable default CatalogSources (prevent OLM reaching internet) |
| 3 | Create mirrored CatalogSources (redhat, certified, community) |
| 4 | Create ITMS for tag-based image pulls (ubi-minimal, VP images) |
| 5 | Mirror OCI Helm charts that oc-mirror can't handle |
| 6 | Fix oc-mirror manifest list failures (skopeo fallback) |
| 7 | Add mirror CA cert to ArgoCD TLS config |
| 8 | Enable OVN routingViaHost (opt-in, lab networks only) |
| 9 | Set up smart HTTP git server for pattern repos |
| 10 | Create patterns-operator-config ConfigMap (GitOps channel override) |

### 5. Install patterns-operator

Due to the OCI image index format issue ([#774](https://github.com/validatedpatterns/patterns-operator/issues/774)), the patterns-operator must be deployed manually rather than via OLM:

```bash
# The bootstrap script will automate this in a future update.
# For now, create SA + RBAC + webhook certs + Deployment manually.
# See scripts/airgap-post-install.sh deploy_operator() function.
```

Once upstream publishes Docker manifest lists (or Quay enables `FEATURE_GENERAL_OCI_SUPPORT`), standard OLM install will work.

### 6. Deploy the pattern

```bash
make airgap-deploy-pattern
```

This deploys the Pattern CR directly (bypasses `pattern.sh` which auto-detects GitHub URLs). The CR reads `git.repoURL` and `helmRepoUrl` from `values-global.yaml`.

### 7. Wait for ArgoCD apps to sync

ArgoCD creates child applications for each component. Monitor progress:

```bash
oc get applications.argoproj.io -A \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# Check for ImagePull issues
oc get pods -A | grep -E "ImagePull|ErrImage"
```

Expected apps: `acm`, `vault`, `storage`, `kyverno`, `openshift-external-secrets`, plus CoCo-specific apps.

### 8. Load secrets into Vault

```bash
cd ~/coco-pattern
./pattern.sh make load-secrets
```

Requires Vault pod to be Running and unsealed (ArgoCD handles this automatically).

## Configuration Files

### values-global.yaml (disconnected settings)

```yaml
main:
  git:
    repoURL: http://JUMP_HOST_IP:8080/coco-pattern.git  # smart HTTP
    revision: dev/airgap-testing
  patternsOperator:
    source: cs-community-operator-index-v4-21  # mirrored CatalogSource
    channel: fast
  gitops:
    operatorSource: cs-redhat-operator-index-v4-21
    channel: latest  # must match mirrored catalog channel
  multiSourceConfig:
    enabled: true
    helmRepoUrl: quay.example.com:443/mirror/validatedpatterns  # OCI, repos must be public
```

### Quay mirror requirements

The following Quay repos **must be public** for ArgoCD to pull OCI Helm charts (ArgoCD has known OCI credential bugs #25513, #26311):

- `mirror/validatedpatterns/clustergroup`
- `mirror/validatedpatterns/acm`
- `mirror/validatedpatterns/hashicorp-vault`
- `mirror/validatedpatterns/openshift-external-secrets`
- `mirror/validatedpatterns/trustee`
- `mirror/validatedpatterns/sandboxed-containers`
- `mirror/validatedpatterns/sandboxed-policies`
- `mirror/validatedpatterns/pattern-install`
- `mirror/kyverno/charts/kyverno`

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make airgap-mirror` | Mirror content to disconnected registry |
| `make airgap-post-install` | Run full post-install bootstrap |
| `make airgap-deploy-pattern` | Deploy Pattern CR directly |
| `make airgap-sync-repos` | Sync git working copies to bare HTTP repos |

## Troubleshooting

### "manifest unknown" during OCP install
The `openshift-install` binary version must match the mirrored release. Rebuild the ISO if certificates expired (>24 hours old).

### ArgoCD apps stuck at "Unknown" sync
Check if Helm chart repos are public on Quay. Verify with:
```bash
curl -sk https://quay.example.com:443/v2/mirror/validatedpatterns/clustergroup/tags/list
# Should return 200 with JSON, not 401
```

### "unexpected EOF" from patterns-operator git clone
The patterns-operator uses go-git which doesn't support Apache dumb HTTP. Use `git-http-server.py` (smart HTTP via `git-http-backend` CGI) on port 8080.

### GitOps operator subscription wrong channel
The patterns-operator hardcodes the GitOps channel. The bootstrap script creates a `patterns-operator-config` ConfigMap to override it to `latest` (the only channel available in the mirrored catalog).

### Vault ImagePullBackOff
The VP Helm chart references `registry.connect.redhat.com/hashicorp/vault:VERSION-ubi`. Add an ITMS entry for `registry.connect.redhat.com/hashicorp` and mirror the image:
```bash
oc image mirror --insecure=true \
  registry.connect.redhat.com/hashicorp/vault:1.21.4-ubi \
  quay.example.com:443/mirror/hashicorp/vault:1.21.4-ubi
```

### OVN routingViaHost
Only needed when the OVN default gateway can't route to the jump host subnet. This is lab-specific — in a properly routed network, pods can reach the git/registry servers without it. Set `ENABLE_ROUTINGVIAHOST=true` before running the bootstrap.

## Known Issues

| Issue | Root Cause | Status |
|-------|-----------|--------|
| patterns-operator OLM install fails | OCI image index format rejected by Quay | [#774](https://github.com/validatedpatterns/patterns-operator/issues/774) filed |
| ArgoCD OCI Helm auth broken | ArgoCD bugs #25513, #26311 | Workaround: make repos public |
| oc-mirror skips OCI Helm charts | `additionalImages` only handles container images | Bootstrap script mirrors separately |
| `pattern.sh` detects GitHub URL | Reads `git remote get-url origin` | Bypass with `make airgap-deploy-pattern` |
| clustergroup chart caches old helmRepoUrl | Child apps rendered with stale URL | Fixed when OCI URL is correct from start |
