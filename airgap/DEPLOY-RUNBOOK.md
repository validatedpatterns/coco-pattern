# Airgap Deployment Runbook

This runbook covers deploying the CoCo pattern to a disconnected (airgapped)
OpenShift cluster using a **Quay registry** as the sole mirror target.

For a **plain Docker registry** (registry:2) alternative, see
[Appendix A](#appendix-a-plain-docker-registry-alternative).

## Architecture

```text
┌──────────────┐     ┌───────────────────┐     ┌─────────────────┐
│  Upstream    │────▶│  Quay Mirror      │────▶│  OpenShift SNO  │
│  Registries  │     │  (org: mirror)    │     │  (node-02)      │
│  (internet)  │     │                   │     │                 │
└──────────────┘     └───────────────────┘     └─────────────────┘
                            │                        │
                            │   ┌────────────────┐   │
                            └──▶│  Git HTTP      │◀──┘
                                │  Server (:8080)│
                                └────────────────┘

```text

All image content is mirrored to a single Quay org. The cluster pulls
exclusively from the mirror (default catalogs disabled, IDMS/ITMS
redirect all upstream registries). The pattern source code is served
via a local Git HTTP server.

## Duration

| Phase | Description | Duration |
|---|---|---|
| A | Mirror preparation | ~4h (one-time) |
| B | Cluster install | ~35 min |
| C | Pattern deploy | ~2h |
| D | Secrets + attestation | ~30 min |
| **Total** | From ISO boot to 15/15 healthy | **~2.5-3h** |

---

## Prerequisites

### Mirror Content

The Quay mirror must contain all images the pattern resolves. Verify with
`skopeo list-tags` against each repo (the REST API is unreliable for org
robots). Key content:

- OCP release payload (exact installer version, e.g. 4.22.17)
- Operator catalogs (redhat, certified, community — v4.22)
- VP Helm charts (clustergroup, trustee, acm, etc.)
- VP utility images (utility-container, imperative-container, pattern-install)
- Workload images (ubi9/httpd-24, ubi9/ubi)
- Intel DCAP operator + QGS images
- Kyverno images (mirrored from ghcr.io under the `kyverno/` path)
- hashicorp/vault (the version the chart resolves, e.g. 2.1.2-ubi)

### Imageset Pin Check (K16)

Pattern values use range pins (`~0.1.10`, `0.2.*`) resolved at deploy time.
The imageset must mirror the **newest version within each range** — not the
range floor. Run a range-check before every deploy:

```bash
# For each chart pin in values-*.yaml, verify the newest in-range tag
# is present in the mirror
skopeo list-tags docker://<mirror>/validatedpatterns/<chart> | \
  python3 -c "import json,sys; tags=json.load(sys.stdin)['Tags']; print(sorted(tags))"

```

### Credentials and Certificates

```bash
# Mirror registry credentials (robot account)
export MIRROR_REGISTRY=<quay-host>:443/mirror    # INCLUDES the org path
export MIRROR_USER=<robot-username>
export MIRROR_PASS=<robot-token>

# CA certificate chain
cp <quay-ca.pem> ~/.coco-pattern/registry-ca-cert.pem
cat <quay-ca.pem> > ~/combined-ca-bundle.pem

# Intel PCS API key (for PCK provisioning, 32 bytes, no trailing newline)
printf '%s' "<api-key>" > ~/.coco-pattern/intel-pcs-api-key

# DCAP collateral (collected on a connected host, ~30 day freshness)
# ~/.coco-pattern/dcap-offline/platform_collaterals.json

```text

### Values-Secret (Convention Location)

The values-secret file **must** be at `~/values-secret-<pattern>.yaml`.
The Ansible secret loader (`find_vp_secrets`) searches home-directory
conventions and falls back to the repo template — it never reads a
repo-local generated file.

```bash
# Generate (writes to ~/values-secret-<pattern>.yaml)
make gen-secrets

# Uncomment airgap blocks (registry CA, bootstrap secrets)
scripts/enable-airgap-secrets.sh

# Edit the bootstrap_secrets block for your mirror:
#   url: <mirror-host>:443/<org>/validatedpatterns
#   username: <robot-username>
#   password path: ~/.coco-pattern/registry-password
#
# Edit the registryCaCert block:
#   pem path: ~/.coco-pattern/registry-ca-cert.pem

```

### Git Server

The pattern source is served via a local Git HTTP server:

```bash
# Bare repos under ~/public_html/git/
# Smart HTTP on :8080 (started by airgap-post-install.sh step 9)

```text

---

## Phase B: Cluster Install

### B-1: Generate the ISO

```bash
labctl generate \
  --node <node-name> \
  --xlsx <lab-xlsx> \
  --ocp-version <version> \
  --output-dir <output-dir> \
  --mirror-resources ~/oc-mirror-workspace/working-dir/cluster-resources \
  --additional-trust-bundle ~/combined-ca-bundle.pem \
  --http-serve-path ~/public_html

```

### B-2: Boot and Install

```bash
# Mount the ISO via iDRAC/virtual media, one-time boot
# Wait for install (~35 min):
openshift-install agent wait-for install-complete \
  --dir <output-dir>/<version>_build

```text

### B-3: Verify

```bash
export KUBECONFIG=<output-dir>/<version>_build/auth/kubeconfig
oc get clusterversion       # version, Available=True
oc get clusteroperators     # all Available
oc get nodes                # Ready

```

---

## Phase C: Pattern Deploy

### C-1: Airgap Post-Install

```bash
cd ~/coco-pattern

export MIRROR_REGISTRY=<quay-host>:443/mirror   # INCLUDES the org!
export GIT_SERVER=http://<git-host>:8080
export ENABLE_ROUTINGVIAHOST=true               # required for pod→lab egress

scripts/airgap-post-install.sh

```text

This applies:

- IDMS/ITMS/CatalogSources from the oc-mirror workspace
- `mirrorSourcePolicy: NeverContactSource` on all mirror rules
- Repoints any default-catalog subscriptions to the mirrored catalogs
- Configures the Git HTTP server
- Creates the patterns-operator-config ConfigMap
- Enables OVN routingViaHost (verified after applying)

**Verify**: catalog pods Running, routingViaHost=true.

### C-2: Deploy the Pattern

```bash
export PATTERN_DISCONNECTED_HOME=<quay-host>:443/<org>/validatedpatterns

./pattern.sh make install

```

This:

- Creates the patterns-operator Subscription (from the mirrored catalog)
- Creates the Pattern CR (from values-global.yaml)
- Creates the ArgoCD instance (vp-gitops namespace)
- Loads bootstrap secrets (the ArgoCD OCI chart-pull credential)

**Verify**: `Bootstrap phase: 1 secret(s) created` in the output.
If it says 0, the values-secret is not at the convention location.

### C-3: ArgoCD CA + Bootstrap (parallel with C-2)

Run in parallel with the pattern deploy — must fire as soon as ArgoCD
exists:

```bash
# Wait for vp-gitops namespace
until oc get ns vp-gitops &>/dev/null; do sleep 10; done

# Inject the mirror CA into ArgoCD's TLS trust
oc patch configmap argocd-tls-certs-cm -n vp-gitops \
  --type merge -p "{\"data\":{\"<mirror-host>\":\"$(cat ~/.coco-pattern/registry-ca-cert.pem)\"}}"

# Roll the deployments to pick up the CA
oc get deployments -n vp-gitops --no-headers -o name | \
  while read dep; do oc rollout restart "$dep" -n vp-gitops; done
oc rollout status deployment/vp-gitops-repo-server -n vp-gitops

# Load bootstrap secrets (if not already done by pattern.sh)
make load-bootstrap

# Verify: the secret exists, is labeled, and has the correct URL
oc get secret mirror-registry-helm-oci -n vp-gitops \
  -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}'
# Expected: repository

```text

### C-4: Known Timing Issues

Three issues occur consistently in disconnected deployments. Each has a
one-line fix:

#### MCE Subscription (30-60 min after C-1)

The MCH operator creates the `multicluster-engine` subscription with
`source: redhat-operators` (the default catalog, disabled in airgap).
The MCH then blocks in `Installing`.

```bash
oc patch subscriptions.operators.coreos.com multicluster-engine \
  -n multicluster-engine --type merge \
  -p '{"spec":{"source":"<mirrored-catalog-name>","sourceNamespace":"openshift-marketplace"}}'

```

#### ITMS Org-Prefix (kyverno pods ImagePullBackOff)

The manual ITMS mirrors must include the org prefix for Quay targets.

```bash
# Verify: all mirrors should include /<org>/
oc get itms itms-manual-mirrors -o json | \
  python3 -c "import json,sys; [print(m['source'],'->',m['mirrors']) for m in json.load(sys.stdin)['spec']['imageTagMirrors']]"

```text

If any mirror is missing the org, patch the ITMS and delete the affected pods.

#### Initdata Staleness (CVM workloads in CreateContainerError)

The `cc_init_data` annotation is immutable at pod creation. Workload pods
created before the KBS is ready will retry indefinitely with stale initdata.

```bash
# Prerequisite: KBS Running and attestation returning 200
oc delete pod -n hello-openshift --all
oc delete pod -n kbs-access --all

```

---

## Phase D: Secrets and Attestation

### D-1: Load Vault Secrets

```bash
# Waits for vault-0, then loads all secrets from the values-secret file
./pattern.sh make load-secrets

```text

### D-2: PCK Provisioning (parallel with D-1)

```bash
export INTEL_PCS_API_KEY=$(cat ~/.coco-pattern/intel-pcs-api-key)
make dcap-pck-provision

# Restart the QGS to pick up the provisioned PCK
oc delete pod -n intel-dcap-operator-system -l app=intel-tdx-dcap-qgs

```

### D-3: Firmware Reference Values

```bash
# Collect from the live node (re-run if the node was reinstalled)
make collect-firmware-refvals
./pattern.sh make load-secrets   # reload with fresh values

```text

---

## Verification

```bash
# All applications Synced+Healthy
oc get applications.argoproj.io -A --no-headers | \
  awk '$3!="Synced" || $4!="Healthy"'
# Expected: no output

# Attestation returning 200
oc logs -n trustee-operator-system deployment/trustee-deployment \
  --tail=5 | grep "attest.*200"

# CVM workloads pulling from the mirror
oc get pods -n hello-openshift -o jsonpath='{.items[0].spec.containers[0].image}'

```

---

## Appendix A: Plain Docker Registry Alternative

A plain Docker registry (registry:2) can be used instead of Quay. The key
differences:

| Aspect | Quay | Docker registry |
|---|---|---|
| Content path | `/<org>/<repo>` (org prefix) | `/<repo>` (flat) |
| MIRROR_REGISTRY | `<host>:443/<org>` | `<host>:8443` (no org) |
| Authentication | Robot account (token) | htpasswd (init user) |
| CA | Quay CA chain | Self-signed CA |
| Setup | Pre-existing Quay | podman run registry:2 |

### Docker Registry Setup

```bash
# One-time: generate CA, htpasswd, config, and start the container
# (see the Phase 0 section of the historical runbook for the full script)

# The MIRROR_REGISTRY does NOT include an org prefix:
export MIRROR_REGISTRY=<host>:8443

# All other configuration is the same, minus the org prefix:
#   helmRepoUrl: <host>:8443/validatedpatterns
#   image overrides: <host>:8443/ubi9/...
#   PATTERN_DISCONNECTED_HOME: <host>:8443/validatedpatterns
#   ITMS mirrors: <host>:8443/<path> (no org)

```text

The Docker registry stores all manifest types (including OCI image indexes
and hybrid manifests that Quay may reject). However, it lacks Quay's
org-based isolation, robot accounts, and API — use Quay where available.
