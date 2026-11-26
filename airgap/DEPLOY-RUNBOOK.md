# Airgap Deployment Runbook

This runbook covers deploying the CoCo pattern to a disconnected (airgapped)
OpenShift cluster using a **Quay registry** as the sole mirror target.

For a **plain Docker registry** (registry:2) alternative, see
[Appendix A](#appendix-a-plain-docker-registry-alternative).

Static verification of the values chain in both connectivity modes (the
connected default and the airgap overlay) is `make render-gate` — it runs
in CI on every push and pull request, for OCP 4.22 and 5.0.

## Qualified scope

**OCP 4.22** (connected + disconnected) is fully qualified on bare-metal
Intel TDX: 15/15 applications Synced+Healthy, CoCo TDX attestation
Affirming.

**OCP 5.0** is qualified on a narrower scope — **bare-metal Intel TDX,
OCP 5.0.2, RHCOS 9 payload** (`osImageStream: rhel-9`). The
qualification record is the `deploy/ocp5-airgap-20261125` deploy branch
on the pattern fork (the committed cluster state of the qualified run);
the hardening fixes on `feat/ocp5-compatibility` post-date that record
and re-qualify through the render gate and the mocked-`oc` suites in
`tests/`. Two hard requirements:

- The installer must run the RHCOS 9 payload (`--os-image-stream rhel-9`
  at `labctl generate`, B-1 — matching the qualified 5.0.2 deploy); the
  RHEL 10 payload is unqualified.
- The mirror and the pattern values must agree on the minor:
  `IMAGESET_CONFIG=airgap/imageset-config-5.0.yaml` (not the 4.22
  default) with `global.clusterVersion: "5.0"`.

**Unverified on 5.0:** the RHEL 10 payload (`osImageStream: rhel-10`),
AMD SEV-SNP, GPU profiles, and every other topology (Azure peer-pods,
hub/spoke, HCP). Setting `global.clusterVersion: "5.0"` alone is
therefore NOT sufficient for a qualified 5.0 deploy — the imageset,
the payload stream and (for pre-DCAP-v0.27.0 clusters) the Intel DCAP
migration notes below all apply.

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
needed for a 4.22 mirror; a 5.0 mirror must point at the 5.0 imageset):

```bash
# 4.22 mirror
make airgap-mirror MIRROR_REGISTRY=quay.example.com:443/mirror

# 5.0 mirror (version-specific imageset — REQUIRED on 5.0)
make airgap-mirror MIRROR_REGISTRY=quay.example.com:443/mirror \
     IMAGESET_CONFIG=airgap/imageset-config-5.0.yaml
```

The Quay mirror must contain all images the pattern resolves. Verify with
`skopeo list-tags` against each repository (the REST API is unreliable for org
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

**OCP 5.0 platform channel:** 5.0.2 is published only in `candidate-5.0`
(`stable-5.0`/`fast-5.0` graphs are at 5.0.1), so
`imageset-config-5.0.yaml` pins the platform to `candidate-5.0` with
min=max=5.0.2. Re-point the channel to `stable-5.0` once 5.0.2 is
promoted. The 4.22-stream oc-mirror binary resolves 5.0 platform pins
without issue (verified by dry-run).

**Intel DCAP channel migration (moving an existing cluster to 5.0 only):**
the version overlay pins the DCAP subscription per minor — 4.22 keeps the
`alpha` channel (`intel-tdx-dcap-operator` v0.1.0, AllNamespaces
OperatorGroup, matching `imageset-config-4.22.yaml`, which mirrors `alpha`
only); 5.0 pins `stable` (v0.27.0, OwnNamespace-only — the only channel in
the 5.0 catalog, matching `imageset-config-5.0.yaml`). A fresh 4.22
disconnected install therefore works unchanged, and 4.22 installs are never
migrated by this pattern. When you MOVE a cluster to 5.0, Intel does not
support an in-place upgrade from v0.1.0 to v0.27.0: on the 4.22 install,
delete the old subscription, OperatorGroup, CSV and CRs before redeploying
with `global.clusterVersion: "5.0"`.

### Imageset Pin Check (K16)

Pattern values pin the VP charts with a mix of ranges and exact pins:

| Chart | Pin |
|---|---|
| clustergroup | `0.9.60` (exact) |
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
conventions and falls back to the repository template — it never reads a
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
these values:

```yaml
global:
  airgap: true
  mirrorRegistry: <mirror-root-including-org>          # e.g. quay.example.com:443/mirror
  clusterVersion: "<minor>"                            # e.g. "5.0" — selects the version overlay
main:
  clusterGroupName: baremetal
  git:
    repoURL: http://<git-host>:8080/coco-pattern.git   # served by scripts/git-http-server.py
    revision: <deploy-branch>
  patternsOperator:
    source: cs-community-operator-index-v<minor-dashed>   # 4.22 → v4-22, 5.0 → v5-0
  gitops:
    operatorSource: cs-redhat-operator-index-v<minor-dashed>
  multiSourceConfig:
    helmRepoUrl: <mirror-root-including-org>/validatedpatterns
```

**OCP 5.0 — payload stream pin (required):** the qualified 5.0 deploy
runs the **RHCOS 9** payload — pass `--os-image-stream rhel-9` at
`labctl generate` (B-1). Left unset, the installer defaults to RHEL 10 —
an unqualified payload (the CoCo/kata/edk2 artifacts differ per stream;
see the qualified-scope section). 4.22 needs no pin (RHCOS 9 is its only
stream).

The mirrored catalog names are version-derived (see the sharedValueFiles
tpl in `values-baremetal.yaml`): the airgap overlay is
`overrides/values-baremetal-airgap-<minor-dashed>.yaml` (`5.0` →
`values-baremetal-airgap-5-0.yaml`); 4.22 alone keeps the unsuffixed
`values-baremetal-airgap.yaml` for render byte-compatibility with the
qualified 4.22 deploy. A new minor needs its overlay file and its
`airgap/imageset-config-<minor>.yaml`.

- `global.mirrorRegistry` must equal `$MIRROR_REGISTRY` (org path included).

#### Workload image rewrite (`<chart>.image` helpers)

CoCo guest VMs pull their images directly — there is no IDMS/ITMS inside the
CVM, so a `registry.redhat.io/ubi9/...` reference cannot be redirected at
pull time. In airgap mode the workload charts (hello-openshift,
kbs-access-curl, kbs-access-sealed) rewrite each image against
`global.mirrorRegistry` in their `<chart>.image` helper, using the oc-mirror
source-path convention — the registry hostname is stripped and the mirror
root prefixed:

```text
registry.redhat.io/ubi9/httpd-24@sha256:...
  → quay.example.com:443/mirror/ubi9/httpd-24@sha256:...
```

The mirror root must include the org path for Quay targets (it is the same
value oc-mirror was pointed at). Three guards, all asserted by
`scripts/verify/render-gate.sh`:

- an image already under the mirror root is returned unchanged (otherwise it
  would be double-prefixed: `.../mirror/mirror/ubi9/...`);
- the host is only stripped when the first segment actually looks like one
  (contains `.` or `:`, or is `localhost`) — a hostless reference such as
  `library/httpd:2.4` keeps its org segment;
- rendering fails fast when airgap mode is on and the mirror is unset or a
  placeholder — a missing value would otherwise surface as
  ImagePullBackOff inside the CVMs minutes later.

The helper is duplicated verbatim in the three path-rendered charts (they
cannot share a library template); the render gate asserts the copies stay
identical.

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
  --os-image-stream rhel-9 \
  --output-dir <output-dir> \
  --mirror-resources ~/oc-mirror-workspace/working-dir/cluster-resources \
  --additional-trust-bundle ~/combined-ca-bundle.pem \
  --http-serve-path ~/public_html

```

`--os-image-stream` is the **OCP 5.0 payload pin** — RHCOS 9 for the
qualified configuration (see the payload stream pin note above). Omit it
only on 4.22 (single stream).

### B-2: Boot and Install

**Executable order (OCP 5.0): boot → wait for the API → routing
prerequisite → `install-complete` → full bootstrap (C-1).** On 4.22 the
prerequisite is not needed — go straight from boot to
`install-complete`, then C-1.

**OCP 5.0: the MCO needs mirror egress DURING bootstrap.** The 5.0
machine-config controller discovers OSImageStreams by inspecting the
release image-stream images (`ocp-v5.0-art-dev` digests, resolved through
the IDMS to the mirror). On labs where pod→off-cluster egress requires
OVN `routingViaHost` (see C-1 step 8), the controllerconfig never
completes, `machine-config` goes Degraded, and `wait-for install-complete`
exits 6 ("failed to initialize the cluster") after its 40-minute window —
while the node itself is installed and every image referenced IS in the
mirror. 4.22 does not hit this: its MCO does no image inspection at
bootstrap.

Remedy (verified on the 5.0.2 airgap run) — the four steps in this exact
order:

```bash
# 1) Boot the ISO via iDRAC/virtual media (one-time boot), then wait for
#    the cluster API to answer:
export KUBECONFIG=<output-dir>/<version>_build/auth/kubeconfig
until oc get clusterversion >/dev/null 2>&1; do sleep 30; done
cd ~/coco-pattern

# 2) Routing prerequisite — BEFORE install-complete and before anything
#    else lands (the 5.0 MCO needs pod egress to the mirror during
#    bootstrap, and no other cluster state may precede the controller's
#    first render — MCO-466 bootstrap variance; routingViaHost alone is
#    render-neutral). The flag is fail-closed: wrong version, non-OVN
#    network, failed reads and failed patches all abort:
scripts/airgap-post-install.sh --prereq-only
# → must print "Prerequisite satisfied: routingViaHost=true"
#
# NOTE: "the API answers" does not imply the Network CR exists yet — a
# young cluster can reject the network.operator read/write with
# "no matches for kind" or NotFound. That is a RETRY, not a failure:
# wait ~30 s and re-run --prereq-only (the qualification run needed one
# retry). Only a real error message from the flag (wrong version, non-OVN,
# failed patch) is a stop condition.

# 3) Let the installer finish (exit=0 required; machine-config must not
#    be Degraded — the MCD exits bootstrap mode on its own, no repairs):
openshift-install agent wait-for install-complete \
  --dir <output-dir>/<version>_build

# 4) Full bootstrap (catalogs, IDMS, trustedCA, git server) — C-1:
#    [C-1: Airgap Post-Install](#c-1-airgap-post-install)
```

**If the MCD is already wedged** (node annotation references a missing
install-time rendered config, `currentconfig` absent on disk), the daemon
cannot self-heal and restarts do not help. This state means the
prerequisite above was not applied in time. Do NOT hand-patch node
annotations or daemon state files (`currentConfig`/`desiredConfig`
pointing, `/run/machine-config-daemon-force`) — that repair is
unsupported and was recorded as a deviation when it was last used.
Instead: confirm the diagnosis below, then **reinstall the node** (the
sanctioned path — the install is ~35 min) with the prerequisite applied
at step 2. For sustained problems, escalate to Red Hat support with the
`machine-config` controller/MCD logs and the node's
`machineconfiguration.openshift.io/*` annotations.

Diagnosis cues that this is egress and not missing mirror content: the
controller log shows BOTH the source and the mirror failing with
`dial tcp <mirror-ip>:443: i/o timeout` (TCP-level, from pods), while the
same digests resolve from the deploy host via skopeo.

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

> **Read C-2a first.** The Pattern CR must point at the airgap Git server
> before this command runs; getting it wrong is silent (the install exits 0
> while the CR keeps an unreachable URL).

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

#### C-2a: Point the Pattern CR at the airgap Git server (`TARGET_ORIGIN`)

`pattern.sh` renders the Pattern CR's `spec.gitSpec.targetRepo` from the Git
remote the deploy clone tracks. A clone that tracks the upstream GitHub
remote therefore produces a CR the disconnected cluster can never clone:

```text
status.errorMessage: … cloning pattern repo … no route to host
```

**Do this before the first `make install`.** Export `TARGET_ORIGIN` with the
name of the remote that resolves to the HTTP Git server — the same URL used
in `main.git.repoURL` — so the CR is born correct:

```bash
# Remote names vary per clone: `origin` is the HTTP server on the lab deploy
# host, while `github` tracks upstream. Pick the one whose URL is the HTTP
# Git server, then export its NAME (not its URL).
git remote -v

export TARGET_ORIGIN=origin            # the remote that IS the HTTP Git server
export TARGET_BRANCH=<deploy-branch>
export PATTERN_DISCONNECTED_HOME=<quay-host>:443/<org>/validatedpatterns
./pattern.sh make install
```

Patching the CR after the fact is **not** a durable fix. Verified on a live
airgap cluster: a later plain `./pattern.sh make install` (no
`TARGET_ORIGIN`) re-rendered
`--set main.git.repoURL="https://github.com/…"`, overwrote the patched
`targetRepo`, and **still exited 0** — its health check only reads ArgoCD
applications, so the run reports success while silently breaking the CR for
the next reconcile.

If a CR already exists with the wrong URL, repair it and then re-run *with*
`TARGET_ORIGIN` exported, so the value survives:

```bash
GIT_HTTP_URL=http://<git-host>:8080/coco-pattern.git   # the HTTP Git server
PATTERN_NS=$(oc get pattern -A -o jsonpath='{.items[0].metadata.namespace}')
PATTERN_NAME=$(oc get pattern -A -o jsonpath='{.items[0].metadata.name}')
oc patch pattern "$PATTERN_NAME" -n "$PATTERN_NS" --type merge \
  -p "{\"spec\":{\"gitSpec\":{\"targetRepo\":\"$GIT_HTTP_URL\"}}}"

export TARGET_ORIGIN=<remote-name-for-that-URL>
./pattern.sh make install
```

`make airgap-deploy-pattern` is **not** a substitute: it skips the remote
derivation, but on a cluster that already has a Pattern CR it is refused by
the `only one Pattern resource is allowed` admission webhook, and it targets
a different namespace than `pattern.sh` installs into. Making the two flows
compose is tracked upstream (see the PR's follow-up issue).

**Verify** (run this after *every* re-run, not just the first):

```bash
oc get pattern "$PATTERN_NAME" -n "$PATTERN_NS" \
  -o jsonpath='{.spec.gitSpec.targetRepo}{"\n"}'
# Expected: the HTTP Git server URL — a github.com URL here means the next
# reconcile will fail, even if `make install` just reported success
```

### C-3: Point the cluster proxy at the mirror CA, then verify it

**Step 1 — make the install-time bundle the cluster trust anchor.** The
install-time `--additional-trust-bundle` (B-1) writes the mirror CA into
`openshift-config/user-ca-bundle`, but that alone does **not** make it the
cluster trust bundle: `proxy/cluster.spec.trustedCA.name` stays empty, so
every `config.openshift.io/inject-trusted-cabundle` ConfigMap — including
the `trusted-ca-bundle` the clustergroup chart renders in `vp-gitops` —
gets populated with the default system bundle only. Without this step the
repo-server's first chart fetch fails:

```text
helm registry login quay.example.com:443 … x509: certificate signed by unknown authority
```

This is **step 7 of `scripts/airgap-post-install.sh`**
(`configure_cluster_trusted_ca`, airgap-gated and idempotent — it
validates the bundle with openssl, preserves any different existing trust
anchor, writes conditionally on the resourceVersion, and verifies the
injection reconciled). Because the bootstrap runs before the pattern
deploys, the injected ConfigMaps are born with the mirror CA already in
them — the post-deploy repo-server restart below is only needed when the
patch is applied *after* a pattern deploy (e.g. recovery on an existing
cluster; re-running the full script is the preferred way — every step is
idempotent):

If you must patch by hand (a full script re-run is not wanted), apply the
SAME preservation logic — never an unconditional merge patch, which
silently drops a different anchor the cluster already trusts:

```bash
# 1) Read the CURRENT anchor — abort if it is set to anything other than
#    user-ca-bundle or empty:
oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}{"\n"}'
#    "" or "user-ca-bundle" → safe to continue; anything else → merge the
#    mirror CA into THAT bundle instead, do not repoint.

# 2) Only then patch (still check the readout afterwards):
oc patch proxy cluster --type merge \
  -p '{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'
oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}{"\n"}'   # → user-ca-bundle
```

**Step 2 — roll the repo-server** (recovery path only, when step 1 was
applied after the pattern deploy) so the `fetch-ca` init container
re-concatenates the now-injected bundle (with the kube root CA) into the
CA bundle the repo-server uses:

```bash
oc rollout restart deployment/vp-gitops-repo-server -n vp-gitops
oc rollout status  deployment/vp-gitops-repo-server -n vp-gitops --timeout=5m
```

Both steps are safe to repeat: the `proxy` patch is a no-op when the field
already holds that value, while the `rollout restart` deliberately triggers
another rollout each time (that is what makes the bundle get picked up).
The patch is scripted as step 7 of `scripts/airgap-post-install.sh`
(fail-closed: it preserves a different existing trust anchor and verifies
the bundle was reconciled before continuing).

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
# check that step 1 was applied and that the --additional-trust-bundle used
# at ISO build contained the mirror CA)
```

Bootstrap secrets are loaded by the pattern deploy (C-2); `make
load-bootstrap` is the standalone fallback.

#### C-3a: Recover a first sync that failed before the CA was trusted

If the pattern was deployed before C-3 was applied, the root application
is parked in `ComparisonError` with an x509 error and nothing downstream
syncs. After applying both C-3 steps, re-run the install and confirm the
root application recovers:

```bash
# TARGET_ORIGIN must stay exported — a plain re-run re-renders the CR's
# targetRepo from the tracked remote (see C-2a)
export TARGET_ORIGIN=<remote-name-for-the-HTTP-Git-URL>
./pattern.sh make install     # expect exit 0 and "All assertions passed"

oc get application coco-pattern-baremetal -n vp-gitops \
  -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
# Expected: Synced/Healthy (or Progressing while waves converge)
```

If the root app still reports `failed to login to registry … x509`, the
mirror CA is not in the repo-server bundle — re-check the C-3 grep before
concluding anything else. A healthy repo-server with an incomplete bundle
is the failure mode this section exists to prevent.

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

The Docker registry stores all manifest types (including OCI image indices
and hybrid manifests that Quay may reject). However, it lacks Quay's
org-based isolation, robot accounts, and API — use Quay where available.
