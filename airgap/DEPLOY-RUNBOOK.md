# Airgap Deployment Runbook

This runbook covers deploying the CoCo pattern to a disconnected (airgapped)
OpenShift cluster using a **Quay registry** as the sole mirror target.

For a **plain Docker registry** (registry:2) alternative, see
[Appendix A](#appendix-a-plain-docker-registry-alternative).

Static verification of the values chain in both connectivity modes (the
connected default and the airgap overlay) is `make render-gate` — it runs
in CI on every push and pull request.

## Architecture

```text
┌──────────────┐     ┌───────────────────┐     ┌─────────────────┐
│  Upstream    │────▶│  Quay Mirror      │────▶│  OpenShift SNO  │
│  Registries  │     │  (org: mirror)    │     │  (SNO)          │
│  (internet)  │     │                   │     │                 │
└──────────────┘     └───────────────────┘     └─────────────────┘
                            │                        │
                            │   ┌────────────────┐   │
                            └──▶│  Git HTTP      │◀──┘
                                │  Server (:8080)│
                                └────────────────┘

```

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

Populate the mirror from a connected host (the imageset defaults to
`airgap/imageset-config-4.22.yaml` — no `IMAGESET_CONFIG` override is
needed for a 4.22 mirror):

```bash
make airgap-mirror MIRROR_REGISTRY=<mirror-root-including-org>
# e.g. make airgap-mirror MIRROR_REGISTRY=quay.example.com:443/mirror
```

The Quay mirror must contain all images the pattern resolves. Verify with
`skopeo list-tags` against each repo (the REST API is unreliable for org
robots). Key content:

- OCP release payload (exact installer version, e.g. 4.22.17)
- Operator catalogs (redhat, certified, community — v4.22)
- VP Helm charts (clustergroup, trustee, acm, etc.)
- VP utility images (utility-container, imperative-container, pattern-install;
  the bootstrap's mirroring step verifies pattern-install is present in the
  mirror and fails fast if not)
- Workload images (ubi9/httpd-24, ubi9/ubi)
- Intel DCAP operator + QGS images
- Kyverno images — `ghcr.io/kyverno/*` plus the hook images
  `registry.k8s.io/kubectl` and `ghcr.io/kyverno/readiness-checker`
  (the kyverno chart itself is vendored in-repo at `charts/vendor/kyverno`;
  no kyverno OCI chart artifact is mirrored)
- hashicorp/vault (the version the chart resolves, e.g. 2.1.2-ubi)

### Imageset Pin Check (K16)

Pattern values pin the VP charts with a mix of ranges and exact pins:

| Chart | Pin |
|---|---|
| clustergroup | `0.9.58` (exact) |
| acm | `0.1.*` |
| hashicorp-vault | `0.1.11` (exact) |
| trustee | `0.10.*` |
| sandboxed-containers | `0.2.*` |
| sandboxed-policies | `0.2.*` |
| openshift-external-secrets | `0.0.*` |

The range pins resolve to the **newest version within each range** at
deploy time — not the range floor — so the imageset must mirror that
newest in-range tag (the exact pins are mirrored as-is). Run a range-check
before every deploy:

```bash
# For each chart pin in values-*.yaml, verify the newest in-range tag
# is present in the mirror
skopeo list-tags docker://<mirror>/validatedpatterns/<chart> | \
  python3 -c "import json,sys; tags=json.load(sys.stdin)['Tags']; print(sorted(tags))"

```

### Credentials and Certificates

```bash
# Mirror registry credentials (robot account)
export MIRROR_REGISTRY=quay.example.com:443/mirror  # org path included (Quay)
export MIRROR_USER=<robot-username>
export MIRROR_PASS=<robot-token>

# CA certificate chain
cp <quay-ca.pem> ~/.coco-pattern/registry-ca-cert.pem
cat <quay-ca.pem> > ~/combined-ca-bundle.pem

# Intel PCS API key (for PCK provisioning, 32 bytes, no trailing newline)
printf '%s' "<api-key>" > ~/.coco-pattern/intel-pcs-api-key

# DCAP collateral (collected on a connected host, ~30 day freshness)
# ~/.coco-pattern/dcap-offline/platform_collaterals.json

```

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

### Disconnected value delta (deploy branch)

The committed tree is a working **connected** install; every disconnected
delta is a **config-only change on the deploy branch**. The disconnected
deploy branch used in validation differs from the connected one by exactly
these eight values:

```yaml
global:
  airgap: true
  mirrorRegistry: <mirror-root-including-org>          # e.g. quay.example.com:443/mirror
main:
  clusterGroupName: baremetal
  git:
    repoURL: http://<git-host>:8080/coco-pattern.git   # served by scripts/git-http-server.py
    revision: <deploy-branch>
  patternsOperator:
    source: cs-community-operator-index-v4-22
  gitops:
    operatorSource: cs-redhat-operator-index-v4-22
  multiSourceConfig:
    helmRepoUrl: <mirror-root-including-org>/validatedpatterns
```

- `global.mirrorRegistry` must equal `$MIRROR_REGISTRY` (org path included).
- Step 3e of `scripts/airgap-post-install.sh` fails fast — before the
  Pattern CR is applied — if `main.multiSourceConfig.helmRepoUrl`,
  `main.gitops.operatorSource` or `main.patternsOperator.source` is missing
  or still the connected default while `global.airgap: true`.

### Git Server

The pattern source is served via a local Git HTTP server:

```bash
# Bare repos under ~/public_html/git/
# Smart HTTP on :8080 (started by airgap-post-install.sh step 9)

```

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

```

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

export MIRROR_REGISTRY=quay.example.com:443/mirror  # org path included (Quay)
export GIT_SERVER=http://<git-host>:8080
export ENABLE_ROUTINGVIAHOST=true               # required for pod→off-cluster egress

scripts/airgap-post-install.sh

```

This applies:

- IDMS/ITMS/CatalogSources from the oc-mirror workspace
- `mirrorSourcePolicy: NeverContactSource` on all mirror rules
- Repoints any default-catalog subscriptions to the mirrored catalogs
- Configures the Git HTTP server
- Creates the patterns-operator-config ConfigMap
- Enables OVN routingViaHost (verified after applying)

Post-deploy safety net: `make airgap-repoint-subs` re-runs the
default-catalog subscription repoint standalone — safe at any time (e.g.
after MCH deploys its runtime subscriptions); ArgoCD-owned subscriptions
are skipped via the tracking-id annotation.

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

### C-3: Verify the ArgoCD mirror-CA trust

The mirror CA reaches ArgoCD through the cluster trust bundle, not through
any post-install step: the install-time `--additional-trust-bundle` (B-1)
bakes the mirror CA into the cluster-wide trust bundle, and the
clustergroup chart renders a `trusted-ca-bundle` ConfigMap in `vp-gitops`
labelled `config.openshift.io/inject-trusted-cabundle: 'true'`, which
OpenShift populates from that cluster trust bundle. The repo-server's
`fetch-ca` init container concatenates it (with the kube root CA) into the
CA bundle the repo-server uses. No out-of-band CA patch is needed or
useful — the previous `argocd-tls-certs-cm` patch was a silent no-op (it
always ran before the `vp-gitops` namespace existed), and the validated
disconnected runs succeeded without it.

Verify once the pattern is deployed and `vp-gitops` exists:

```bash
oc get configmap trusted-ca-bundle -n vp-gitops \
  -o jsonpath='{.metadata.labels.config\.openshift\.io/inject-trusted-cabundle}'
# Expected: true

# The fetch-ca init container concatenated the injected bundle into the
# ca-bundles emptyDir, mounted at /etc/pki/tls/certs in the repo-server.
# Counting BEGIN lines only proves the bundle is non-empty — to prove the
# MIRROR CA specifically is in it, grep for its subject:
MIRROR_CA_SUBJECT=$(openssl x509 -in ~/.coco-pattern/registry-ca-cert.pem -noout -subject | sed 's/^subject=//')
echo "Looking for: $MIRROR_CA_SUBJECT"
oc exec -n vp-gitops deploy/vp-gitops-repo-server -- \
  grep -c "$MIRROR_CA_SUBJECT" /etc/pki/tls/certs/ca-bundle.crt
# Expected: >= 1 (0 means the mirror CA never reached the trust bundle —
# check the --additional-trust-bundle used at ISO build)
```

Bootstrap secrets are loaded by the pattern deploy (C-2); `make
load-bootstrap` is the standalone fallback.

### C-4: Known Timing Issues

Issues seen in disconnected deployments, and their current status:

#### MCE Subscription — FIXED (declarative)

The MCH operator creates the `multicluster-engine` subscription at
runtime; it used to be born on `redhat-operators` (the default catalog,
disabled in airgap) and block in `Installing`. The `acm.mce_operator.source`
override now renders the MCH's `mce-subscription-spec` annotation, so the
subscription is **born on the mirrored catalog** — no patching needed.

`make airgap-repoint-subs` remains the safety net for any other
runtime-created subscription that references a default catalog:

```bash
make airgap-repoint-subs
```

#### ITMS Org-Prefix — FIXED (at apply time)

The manual ITMS mirrors must include the org prefix for Quay targets.
`airgap/itms-manual-mirrors.yaml` uses the `__MIRROR_REGISTRY__` token,
substituted from `$MIRROR_REGISTRY` (org path included) when bootstrap
step 3b applies it — the mirrors always match the registry actually in
use. Verify:

```bash
# All mirrors should include /<org>/ (when the mirror uses an org)
oc get itms itms-manual-mirrors -o json | \
  python3 -c "import json,sys; [print(m['source'],'->',m['mirrors']) for m in json.load(sys.stdin)['spec']['imageTagMirrors']]"
```

#### Initdata Staleness (CVM workloads in CreateContainerError) — REMAINS

The `cc_init_data` annotation is immutable at pod creation. Pods wedged
only because the trust chain was not provisioned yet (KBS not running,
reference values not loaded) **self-heal**: the kubelet keeps retrying
and the pod starts once attestation succeeds. Only stale initdata
*content* requires pod recreation:

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

```

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

```

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

A plain Docker registry (registry:2) can be used instead of Quay. Include
the org path in `$MIRROR_REGISTRY` if your registry uses one (Quay: yes; a
plain registry:2: no). The key differences:

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
# (podman run registry:2). Credential helpers in the Makefile:
#   make cache-registry-ca       # copy the registry CA into ~/.coco-pattern/
#   make gen-mirror-helm-secret  # save the registry password (for the
#                                # ArgoCD OCI chart-pull secret)

# The MIRROR_REGISTRY does NOT include an org prefix:
export MIRROR_REGISTRY=<host>:8443

# All other configuration is the same, minus the org prefix:
#   helmRepoUrl: <host>:8443/validatedpatterns
#   image overrides: <host>:8443/ubi9/...
#   PATTERN_DISCONNECTED_HOME: <host>:8443/validatedpatterns
#   ITMS mirrors: <host>:8443/<path> (no org)

```

The Docker registry stores all manifest types (including OCI image indexes
and hybrid manifests that Quay may reject). However, it lacks Quay's
org-based isolation, robot accounts, and API — use Quay where available.
