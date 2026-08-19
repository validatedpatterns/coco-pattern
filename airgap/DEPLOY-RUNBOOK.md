# Airgap Deployment Runbook

> **Permanent home:** `coco-pattern/airgap/DEPLOY-RUNBOOK.md`
>
> This runbook covers the full lifecycle of an airgap deploy — from one-time jump host
> infrastructure setup through verified TDX attestation on an air-gapped OCP SNO cluster.

---

## Duration Estimate

| Phase | Description | Duration |
|-------|-------------|----------|
| 0 | One-Time Infrastructure Setup | ~30 min (skip on repeat runs) |
| A | Prerequisites and Mirror Wipe | ~15 min |
| B | Full Re-Mirror (oc-mirror v2) | ~3-4 hours |
| C | Cluster Install | ~35 min |
| D | Bootstrap and Pattern Deploy | ~25 min |
| E | DCAP and TDX Attestation | ~15 min (+ pcsclient time if QE ID mismatch) |
| F | Verification and Pass/Fail | ~10 min |
| **Total** | | **~5-6 hours** (first-time add ~30 min) |

---

## PHASE 0: One-Time Infrastructure Setup

> **Skip this phase on repeat runs.** These steps configure the jump host infrastructure
> (mirror registry, git server) that persists across deployments. Run once per jump host.
>
> **Prerequisites:** Internet access on the jump host, `podman` and `openssl`
> installed, and `python3-passlib` or `httpd-tools` for `htpasswd`.

### 0-0: Set Site Variables

```bash
# ── Update these for your environment ──────────────────────────────────────
export MIRROR_REGISTRY=MIRROR_REGISTRY_HOST:8443   # host:port of your mirror registry
export GIT_SERVER_PORT=8080                  # port for local git HTTP server
# ───────────────────────────────────────────────────────────────────────────
export MREG_HOST="${MIRROR_REGISTRY%%:*}"
export MREG_PORT="${MIRROR_REGISTRY##*:}"
```

### 0-1: Mirror Registry Initialisation (ONE-TIME)

The mirror registry is a `docker.io/library/registry:2` container with TLS and htpasswd auth.

```bash
echo "=== 0-1: Mirror Registry Init ==="

# Create directory structure
mkdir -p ~/mirror-registry-certs ~/mirror-registry-config ~/local-registry
mkdir -p ~/.coco-pattern ~/.config/containers/certs.d/${MIRROR_REGISTRY}

# a) Generate CA key + self-signed CA cert (10-year validity)
openssl genrsa -out ~/mirror-registry-certs/ca.key 4096
openssl req -new -x509 -days 3650 \
  -key ~/mirror-registry-certs/ca.key \
  -out ~/mirror-registry-certs/ca.crt \
  -subj "/CN=mirror-registry-ca"
echo "CA cert generated: $(openssl x509 -noout -subject -in ~/mirror-registry-certs/ca.crt)"

# b) Generate server TLS cert signed by the CA (SAN = host IP)
openssl genrsa -out ~/mirror-registry-certs/server.key 4096
openssl req -new \
  -key ~/mirror-registry-certs/server.key \
  -out ~/mirror-registry-certs/server.csr \
  -subj "/CN=${MREG_HOST}"
openssl x509 -req -days 3650 \
  -in  ~/mirror-registry-certs/server.csr \
  -CA  ~/mirror-registry-certs/ca.crt \
  -CAkey ~/mirror-registry-certs/ca.key \
  -CAcreateserial \
  -out ~/mirror-registry-certs/server.crt \
  -extfile <(printf "[v3_req]\nsubjectAltName=IP:${MREG_HOST}\n") \
  -extensions v3_req
echo "Server cert signed by CA"

# c) Generate registry password
# Use printf (NOT echo) — echo appends a newline which breaks Helm registry login (401)
MREG_PASS=$(openssl rand -base64 18 | tr -d '=+/' | head -c 24)
printf '%s' "$MREG_PASS" > ~/.coco-pattern/mirror-registry-password
chmod 600 ~/.coco-pattern/mirror-registry-password
echo "Password saved to ~/.coco-pattern/mirror-registry-password (${#MREG_PASS} bytes, no newline)"

# d) Create htpasswd auth file (bcrypt)
htpasswd -Bbc ~/mirror-registry-config/htpasswd init "$MREG_PASS"
# SELinux: container_file_t label required so registry:2 container can read the file
chcon -t container_file_t ~/mirror-registry-config/htpasswd
echo "htpasswd created for user: init"

# e) Create registry config.yml
cat > ~/mirror-registry-config/config.yml << 'EOF'
version: 0.1
log:
  level: warn
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
http:
  addr: :8443
  tls:
    certificate: /certs/server.crt
    key: /certs/server.key
auth:
  htpasswd:
    realm: basic-realm
    path: /auth/htpasswd
EOF

# f) Create and start podman container
# config.yml → /etc/docker/registry/config.yml (where registry:2 reads it)
# htpasswd → /auth/htpasswd (where config.yml references it)
# certs → /certs/ (where config.yml references server.crt/server.key)
podman create \
  --name local-registry \
  -p "${MREG_PORT}:8443" \
  -v ~/local-registry:/var/lib/registry:z \
  -v ~/mirror-registry-config/config.yml:/etc/docker/registry/config.yml:z \
  -v ~/mirror-registry-config/htpasswd:/auth/htpasswd:z \
  -v ~/mirror-registry-certs:/certs:z \
  docker.io/library/registry:2
podman start local-registry
echo "local-registry container started"

# g) Persist as systemd user service (survives reboots and logout)
mkdir -p ~/.config/systemd/user
podman generate systemd --name local-registry --restart-policy always \
  > ~/.config/systemd/user/local-registry.service
systemctl --user daemon-reload
systemctl --user enable local-registry.service
loginctl enable-linger "$USER"
echo "local-registry systemd user service enabled"

# h) Trust the CA for container tools (per-user, no sudo required)
# podman/skopeo/oc-mirror read from this directory automatically.
# curl: pass --cacert ~/mirror-registry-certs/ca.crt
# oc image mirror: pass --insecure=true
cp ~/mirror-registry-certs/ca.crt ~/.config/containers/certs.d/${MIRROR_REGISTRY}/ca.crt
echo "CA trusted for container tools"

# h2) Skip sigstore attachment lookups for certified vendors
# Intel, HashiCorp, and NVIDIA images on registry.connect.redhat.com lack cosign
# .sig manifests. Without this, oc-mirror fails with "name unknown: Image not found".
mkdir -p ~/.config/containers/registries.d
cat > ~/.config/containers/registries.d/no-sigstore-certified.yaml << 'REGCFG'
docker:
  registry.connect.redhat.com/intel:
    use-sigstore-attachments: false
  registry.connect.redhat.com/hashicorp:
    use-sigstore-attachments: false
  registry.connect.redhat.com/nvidia:
    use-sigstore-attachments: false
REGCFG
echo "Sigstore attachment lookups disabled for certified vendors"

# i) Build combined-ca-bundle.pem (used by labctl --additional-trust-bundle)
# The mirror-registry CA is the only CA required — Quay is not used in this deployment.
cp ~/mirror-registry-certs/ca.crt ~/combined-ca-bundle.pem
echo "combined-ca-bundle.pem created: $(grep -c 'BEGIN CERTIFICATE' ~/combined-ca-bundle.pem) cert(s)"

# j) Verify
CATALOG=$(curl -s -u "init:$MREG_PASS" \
  --cacert ~/mirror-registry-certs/ca.crt \
  https://${MIRROR_REGISTRY}/v2/_catalog)
echo "Registry catalog check: $CATALOG"
[ "$CATALOG" = '{"repositories":[]}' ] && echo "PASS: registry healthy and empty" || echo "WARN: unexpected response"
```

### 0-2: Seed pull-secret.json with Mirror Registry Credentials

The Red Hat pull-secret must be downloaded from [console.redhat.com](https://console.redhat.com) before running this step.

```bash
echo "=== 0-2: Seed pull-secret.json ==="

# Download pull-secret.json from https://console.redhat.com → OpenShift → Downloads
# Place at ~/pull-secret.json before proceeding.

MREG_PASS=$(cat ~/.coco-pattern/mirror-registry-password)
python3 - << 'EOF'
import json, base64, os

ps_path = os.path.expanduser("~/pull-secret.json")
mreg = os.environ["MIRROR_REGISTRY"]
mreg_pass = open(os.path.expanduser("~/.coco-pattern/mirror-registry-password")).read()
mreg_auth = base64.b64encode(f"init:{mreg_pass}".encode()).decode()

with open(ps_path) as f:
    ps = json.load(f)

ps["auths"][mreg] = {
    "auth": mreg_auth,
    "username": "init",
    "password": mreg_pass
}

with open(ps_path, "w") as f:
    json.dump(ps, f, indent=2)

print("Added mirror-registry auth to pull-secret.json")
print("Registries:", list(ps["auths"].keys()))
EOF
```

> **When to re-run:** Only if `~/.coco-pattern/mirror-registry-password` is regenerated.
> The htpasswd auth survives mirror storage wipes — only image data is cleared in Phase A-4.

### 0-3: Local Git Server Initialisation (ONE-TIME per jump host)

The local git HTTP server makes pattern repos available to the cluster's patterns-operator
during the deploy. `scripts/airgap-post-install.sh --sync-repos-only` creates bare repos
and starts the service; subsequent runs auto-sync via the D-1 step.

```bash
echo "=== 0-3: Git Server Init ==="

# a) Clone the pattern repositories (internet required — run before air-gapping)
git clone -b dev/airgap-testing \
  https://github.com/butler54/coco-pattern.git ~/coco-pattern
git clone -b dev/phase1-testing \
  https://github.com/butler54/trustee-chart.git ~/trustee-chart
git clone -b dev/phase1-testing \
  https://github.com/butler54/sandboxed-containers-chart.git ~/sandboxed-containers-chart
git clone -b dev/phase1-testing \
  https://github.com/butler54/sandboxed-policies-chart.git ~/sandboxed-policies-chart

echo "Repos cloned:"
for d in coco-pattern trustee-chart sandboxed-containers-chart sandboxed-policies-chart; do
  echo "  ~/$d: $(git -C ~/$d rev-parse --short HEAD 2>/dev/null)"
done

# b) Create bare repos in ~/public_html/git/ and start git-http.service
cd ~/coco-pattern
export MIRROR_REGISTRY  # must be set from 0-0
scripts/airgap-post-install.sh --sync-repos-only
# This:
#   - Creates ~/public_html/git/*.git bare repos
#   - Creates and enables systemd user service: git-http.service
#   - Reports Git HTTP URLs on the local network

# c) Verify
sleep 3
curl -s "http://localhost:${GIT_SERVER_PORT}/coco-pattern.git/info/refs?service=git-upload-pack" | head -c 80
echo ""
[ $? -eq 0 ] && echo "PASS: git HTTP server responding" || echo "FAIL: check git-http.service status"
```

> **On subsequent runs:** bare repo sync happens automatically in D-1 via
> `scripts/airgap-post-install.sh`. Phase 0-3 is one-time only.

---

## PHASE A: Prerequisites and Mirror Wipe (~15 min)

### A-0: Start tmux Session and Set Up Logging (FIRST STEP)

> **This is the only SSH session you need for the entire run.**
> Start tmux immediately after connecting — all steps, including long-running ones, run as
> named windows within the single `deploy` session. To disconnect safely at any point: `Ctrl-b d`.
> To reconnect to the running session: `ssh jump` then `tmux attach -t deploy`.

```bash
ssh chbutler@user-jump.int.apac-tech-lab.net
tmux new-session -s deploy
```

Everything below runs inside the `deploy` session. Long-running steps open a new named window
(`Ctrl-b c` or via `tmux new-window -n <name>`) and run in the foreground — no nohup needed.
Switch between windows with `Ctrl-b <number>` or `Ctrl-b n/p`.

```bash
# ── Site-specific variables — update these for each deployment environment ──
export MIRROR_REGISTRY=MIRROR_REGISTRY_HOST:8443   # mirror-registry host:port
export GIT_SERVER=http://JUMP_HOST_IP:8080  # local git HTTP server
# Persist to all tmux windows (restore in each window with: eval "$(tmux showenv -g)")
tmux set-environment -g MIRROR_REGISTRY "$MIRROR_REGISTRY"
tmux set-environment -g GIT_SERVER "$GIT_SERVER"

export LOG=~/coco-pattern/logs/run-25-$(date +%Y%m%d).log
mkdir -p ~/coco-pattern/logs
touch "$LOG"
echo "=== Phase 25 Run Start: $(date) ===" | tee -a "$LOG"
echo "LOG=$LOG  MIRROR_REGISTRY=$MIRROR_REGISTRY  GIT_SERVER=$GIT_SERVER" | tee -a "$LOG"
tmux set-environment -g LOG "$LOG"

# local-registry credentials (htpasswd auth, username: init)
export MREG_USER=init
export MREG_PASS=$(cat ~/.coco-pattern/mirror-registry-password)
echo "local-registry credentials loaded (user: $MREG_USER)" | tee -a "$LOG"

# Ensure local-registry CA is trusted by container tools (idempotent)
MREG_HOST="${MIRROR_REGISTRY%%:*}"
MREG_PORT="${MIRROR_REGISTRY##*:}"
mkdir -p ~/.config/containers/certs.d/${MIRROR_REGISTRY}
cp ~/mirror-registry-certs/ca.crt ~/.config/containers/certs.d/${MIRROR_REGISTRY}/ca.crt
echo "local-registry CA trusted for container tools" | tee -a "$LOG"

# Per-user cert dir handles podman/skopeo/oc-mirror TLS.
# curl: pass --cacert ~/mirror-registry-certs/ca.crt
# oc image mirror: pass --insecure=true

# Verify sigstore skip config is in place (created in Phase 0-1 step h2)
ls ~/.config/containers/registries.d/no-sigstore-certified.yaml && \
  echo "Sigstore skip config present" | tee -a "$LOG" || \
  echo "WARN: no-sigstore-certified.yaml missing — Intel/HashiCorp/NVIDIA mirrors may fail" | tee -a "$LOG"
```

> At run end, Claude will SSH in and read this log file for findings analysis.

### A-0.5: Tool Version Verification (MUST PASS before proceeding)

> **Critical:** PATH order issues can cause the wrong binary to be used silently.
> `~/.local/bin` may contain old versions that override `~/bin/` symlinks.
> Every check below must show the expected version. **Stop and fix any mismatch.**

```bash
echo "=== A-0.5: Tool Version Verification ===" 2>&1 | tee -a "$LOG"
OCP_MINOR="4.22"   # Expected OCP minor version for this run

# 1. openshift-install — version string must contain expected OCP minor version
OI_VERSION=$(openshift-install version 2>/dev/null | head -1)
echo "openshift-install: $OI_VERSION" | tee -a "$LOG"
if ! echo "$OI_VERSION" | grep -q "^openshift-install ${OCP_MINOR}"; then
  echo "FAIL: openshift-install reports wrong version (expected ${OCP_MINOR}.x, got: $OI_VERSION)" | tee -a "$LOG"
  echo "Fix: run 'labctl generate ...' first to symlink the correct binary, or check PATH order" | tee -a "$LOG"
  exit 1
fi
echo "PASS: openshift-install is ${OCP_MINOR}.x" | tee -a "$LOG"

# 2. oc-mirror — version string must contain expected OCP minor version
OM_VERSION=$(oc-mirror version 2>&1 | grep -i 'gitversion' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]*' | head -1)
echo "oc-mirror version: $OM_VERSION" | tee -a "$LOG"
if ! echo "$OM_VERSION" | grep -q "^${OCP_MINOR}"; then
  echo "FAIL: oc-mirror reports wrong version (expected ${OCP_MINOR}.x, got: $OM_VERSION)" | tee -a "$LOG"
  echo "Fix: ln -sf ~/ocp_42208_bin/oc-mirror ~/bin/oc-mirror" | tee -a "$LOG"
  exit 1
fi
echo "PASS: oc-mirror is ${OCP_MINOR}.x" | tee -a "$LOG"

# 3. labctl — verify installed
LABCTL_VERSION=$(labctl --version 2>/dev/null)
echo "labctl: $LABCTL_VERSION" | tee -a "$LOG"

# 4. Release image digest alignment (informational — only meaningful after B-2)
OI_DIGEST=$(openshift-install version 2>/dev/null | grep 'release image' | grep -o 'sha256:[0-9a-f]*')
OM_DIGEST=$(grep -o 'sha256-[0-9a-f]*' \
  ~/oc-mirror-workspace/working-dir/cluster-resources/signature-configmap.json 2>/dev/null | \
  head -1 | sed 's/sha256-/sha256:/')
echo "openshift-install release digest: $OI_DIGEST" | tee -a "$LOG"
echo "oc-mirror release digest:         ${OM_DIGEST:-not yet run}" | tee -a "$LOG"
[ -n "$OM_DIGEST" ] && [ "$OI_DIGEST" = "$OM_DIGEST" ] && \
  echo "PASS: release image digests match" | tee -a "$LOG" || \
  echo "INFO: digest mismatch or oc-mirror not yet run (check again after B-2)" | tee -a "$LOG"

echo "A-0.5: Version verification complete at $(date)" | tee -a "$LOG"
```

### A-1: State Verification (check before deleting)

```bash
echo "=== A-1: State Verification ===" 2>&1 | tee -a "$LOG"

cd ~/coco-pattern
git remote get-url origin 2>&1 | tee -a "$LOG"
# EXPECTED: ${GIT_SERVER}/coco-pattern.git
git branch --show-current 2>&1 | tee -a "$LOG"
# EXPECTED: dev/airgap-testing

du -sh ~/oc-mirror-workspace 2>&1 | tee -a "$LOG"

# Check local-registry state (htpasswd auth required)
echo "local-registry catalog:" 2>&1 | tee -a "$LOG"
curl -sk -u "$MREG_USER:$MREG_PASS" https://${MIRROR_REGISTRY}/v2/_catalog 2>&1 | tee -a "$LOG"

grep -c "BEGIN CERTIFICATE" ~/combined-ca-bundle.pem 2>&1 | tee -a "$LOG"
# EXPECTED: 3 (Quay 2-chain + mirror-registry 1 cert)

# Verify pull-secret.json has local-registry credentials (required for cluster node pulls via IDMS)
echo "pull-secret registries:" 2>&1 | tee -a "$LOG"
python3 -c "import json; [print(k) for k in json.load(open('pull-secret.json'))['auths']]" 2>&1 | tee -a "$LOG"
# MUST include: ${MIRROR_REGISTRY}
# If missing, run from appendix A.6 before proceeding

echo "A-1: State verification complete at $(date)" 2>&1 | tee -a "$LOG"
```


### A-3: oc-mirror Workspace Wipe

> **DESTRUCTIVE — confirm A-1 shows correct git branch and mirror-registry state before proceeding.**

```bash
echo "=== A-3: oc-mirror Workspace Wipe ===" 2>&1 | tee -a "$LOG"

ls -la ~/oc-mirror-workspace 2>&1 | tee -a "$LOG"
rm -rf ~/oc-mirror-workspace
echo "oc-mirror-workspace removed" 2>&1 | tee -a "$LOG"

# Also clear any cached oc-mirror state
rm -rf ~/.oc-mirror 2>/dev/null || true
echo "A-3: oc-mirror wipe complete at $(date)" 2>&1 | tee -a "$LOG"
```

### A-4: local-registry Decommission (Stop / Wipe / Restart)

> **DESTRUCTIVE: stop container, wipe storage, restart empty.**
> Container name: `local-registry`. Storage: `~/local-registry` (owned by chbutler — no sudo).
> No auth required for registry API.

```bash
echo "=== A-4: local-registry Decommission ===" 2>&1 | tee -a "$LOG"

# Confirm state before wiping
echo "Container status:" 2>&1 | tee -a "$LOG"
podman ps --format "{{.Names}} {{.Status}}" | grep -i registry 2>&1 | tee -a "$LOG"
echo "Storage size:" 2>&1 | tee -a "$LOG"
du -sh ~/local-registry/ 2>&1 | tee -a "$LOG"

# Stop container
podman stop local-registry 2>&1 | tee -a "$LOG"
echo "local-registry stopped" 2>&1 | tee -a "$LOG"

# Wipe storage (chbutler owns ~/local-registry — no sudo needed)
rm -rf ~/local-registry/*
echo "Storage wiped" 2>&1 | tee -a "$LOG"

# Restart container (reinitializes on empty storage)
podman start local-registry 2>&1 | tee -a "$LOG"
sleep 10

# Verify empty catalog (htpasswd auth required)
curl -sk -u "$MREG_USER:$MREG_PASS" https://${MIRROR_REGISTRY}/v2/_catalog 2>&1 | tee -a "$LOG"
# EXPECTED: {"repositories":[]}

echo "A-4: local-registry decommission complete at $(date)" 2>&1 | tee -a "$LOG"
```

### A-5: Verify Empty State

```bash
echo "=== A-5: Verify Empty State ===" 2>&1 | tee -a "$LOG"

# local-registry catalog must be empty (htpasswd auth required)
echo "local-registry catalog after wipe:" 2>&1 | tee -a "$LOG"
curl -sk -u "$MREG_USER:$MREG_PASS" https://${MIRROR_REGISTRY}/v2/_catalog 2>&1 | tee -a "$LOG"
# EXPECTED: {"repositories":[]}

# oc-mirror workspace must not exist
if [ -d ~/oc-mirror-workspace ]; then
  echo "WARNING: oc-mirror-workspace still exists" 2>&1 | tee -a "$LOG"
else
  echo "PASS: oc-mirror-workspace absent" 2>&1 | tee -a "$LOG"
fi

echo "A-5: Empty state verification complete at $(date)" 2>&1 | tee -a "$LOG"
```

---

## PHASE B: Full Re-Mirror (~3-4 hours)

> **Skip Phase B if mirror-registry already has all required content.**
> Run B-0 to verify. If all checks pass, go directly to Phase C.

### B-0: Verify Mirror Content and Tool Versions (run before deciding to skip Phase B)

> **CRITICAL: oc-mirror must be version-matched to the OCP release being mirrored.**
> Cross-version oc-mirror rebuilds manifests with different SHA256 digests than openshift-install
> expects. This causes every component image pull to return 404 from mirror-registry, with the
> node falling back to internet quay.io (blocked by fake gateway) and stalling.
> `labctl generate` symlinks `~/bin/oc-mirror` from the OCP version bin dir automatically.

```bash
echo "=== B-0: Mirror Content Verification ===" 2>&1 | tee -a "$LOG"
MREG_PASS=$(cat ~/.coco-pattern/mirror-registry-password)

echo "--- oc-mirror version check (MUST match OCP version) ---" 2>&1 | tee -a "$LOG"
oc-mirror version 2>&1 | grep -i 'version\|GitVersion' | tee -a "$LOG"
# MUST contain "4.22" — if not, update symlink: ln -sf ~/ocp_42208_bin/oc-mirror ~/bin/oc-mirror

echo "--- VP OCI Helm charts ---" 2>&1 | tee -a "$LOG"
for chart in clustergroup hashicorp-vault acm openshift-external-secrets \
             sandboxed-containers sandboxed-policies trustee; do
  result=$(curl -sk -u "init:$MREG_PASS" \
    "https://${MIRROR_REGISTRY}/v2/validatedpatterns/${chart}/tags/list" 2>/dev/null)
  tags=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tags','MISSING'))" 2>/dev/null)
  echo "  validatedpatterns/${chart}: ${tags}" 2>&1 | tee -a "$LOG"
done

echo "--- Operator catalog indexes ---" 2>&1 | tee -a "$LOG"
for idx in redhat/redhat-operator-index redhat/certified-operator-index redhat/community-operator-index; do
  result=$(curl -sk -u "init:$MREG_PASS" \
    "https://${MIRROR_REGISTRY}/v2/${idx}/tags/list" 2>/dev/null)
  tags=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tags','MISSING'))" 2>/dev/null)
  echo "  ${idx}: ${tags}" 2>&1 | tee -a "$LOG"
done

echo "--- OCP release image digest check ---" 2>&1 | tee -a "$LOG"
# The release image MUST be accessible at the digest openshift-install has hardcoded.
# This digest is set by the version-matched oc-mirror run — do NOT patch manually.
RELEASE_DIGEST=$(~/ocp_42208_bin/openshift-install version 2>/dev/null | grep 'release image' | awk '{print $NF}' | sed 's/.*@//')
if [ -n "$RELEASE_DIGEST" ]; then
  HTTP=$(curl -sk -u "init:$MREG_PASS" -o /dev/null -w '%{http_code}' \
    "https://${MIRROR_REGISTRY}/v2/openshift/release-images/manifests/sha256:${RELEASE_DIGEST}")
  [ "$HTTP" = "200" ] && echo "PASS: release image digest present" | tee -a "$LOG" || \
    echo "FAIL: release image digest missing (HTTP $HTTP) — must run B-2 with version-matched oc-mirror" | tee -a "$LOG"
fi

echo "--- oc-mirror cluster-resources ---" 2>&1 | tee -a "$LOG"
ls ~/oc-mirror-workspace/working-dir/cluster-resources/ 2>/dev/null | tee -a "$LOG"

echo "B-0: Mirror verification complete at $(date)" 2>&1 | tee -a "$LOG"
```

> **If all VP charts show tags, catalog indexes show v4.22, oc-mirror version matches, and release digest is present → skip to Phase C.**
> If anything is missing or wrong → run Phase B (full re-mirror).

---

### B-1: Sync Repos to Latest

```bash
echo "=== B-1: Sync Repos ===" 2>&1 | tee -a "$LOG"

# Sync git mirror (bare repo) from GitHub
cd ~/public_html/git/coco-pattern.git
git fetch https://github.com/butler54/coco-pattern.git dev/airgap-testing:dev/airgap-testing --force \
  2>&1 | tee -a "$LOG"

# Pull into working copy
cd ~/coco-pattern
git fetch origin 2>&1 | tee -a "$LOG"
git reset --hard origin/dev/airgap-testing 2>&1 | tee -a "$LOG"

# Verify remote and branch
git remote get-url origin 2>&1 | tee -a "$LOG"
# MUST: ${GIT_SERVER}/coco-pattern.git
git branch --show-current 2>&1 | tee -a "$LOG"
# MUST: dev/airgap-testing

# Verify clustergroup chart version in imageset-config
echo "Checking imageset-config clustergroup version:" 2>&1 | tee -a "$LOG"
grep "clustergroup" ~/coco-pattern/airgap/imageset-config-4.22.yaml 2>&1 | tee -a "$LOG"
# EXPECTED: clustergroup:0.9.58

# Verify values-baremetal-airgap.yaml is 2-line shape
echo "Checking values-baremetal-airgap.yaml shape:" 2>&1 | tee -a "$LOG"
cat ~/coco-pattern/values-baremetal-airgap.yaml 2>&1 | tee -a "$LOG"
# EXPECTED: 2 lines with global.catalogSource and global.catalogSourceNamespace

# Verify deprecated scripts are quarantined
echo "Checking scripts/deprecated/:" 2>&1 | tee -a "$LOG"
ls ~/coco-pattern/scripts/deprecated/ 2>&1 | tee -a "$LOG"
# EXPECTED: exactly 3 files (fix-patterns-operator-images.sh, rebuild-patterns-operator-bundle.sh, deploy-pattern-without-operator.sh)

echo "B-1: Repo sync complete at $(date)" 2>&1 | tee -a "$LOG"
```

### B-2: Run oc-mirror v2 (Full Re-Mirror)

> **Long-running (~3-4 hours). Open a new window in the `deploy` session for this step.**
>
> **oc-mirror version must match OCP version.** `labctl generate` (C-1) automatically symlinks
> `~/bin/oc-mirror` from `~/ocp_42208_bin/oc-mirror`. Verify with B-0 before proceeding.
> A version mismatch causes oc-mirror to rebuild manifests with different SHA256 digests than
> openshift-install expects, resulting in 404s on every component image during node boot.

```bash
tmux new-window -n "oc-mirror"   # opens within the current session; switches you into it
eval "$(tmux showenv -g LOG)"; eval "$(tmux showenv -g MIRROR_REGISTRY)"; eval "$(tmux showenv -g GIT_SERVER)"

echo "=== B-2: oc-mirror v2 Full Re-Mirror ===" 2>&1 | tee -a "$LOG"
echo "Started at $(date)" 2>&1 | tee -a "$LOG"

# Verify oc-mirror version before running (must match OCP 4.22)
oc-mirror version 2>&1 | grep -i 'version\|GitVersion' | tee -a "$LOG"
# MUST show 4.22.x — if not, stop and fix: ln -sf ~/ocp_42208_bin/oc-mirror ~/bin/oc-mirror

# Authenticate oc-mirror against local-registry (CA trusted via certs.d from A-0)
podman login ${MIRROR_REGISTRY} \
  --username "$MREG_USER" \
  --password "$MREG_PASS" \
  2>&1 | tee -a "$LOG"
# EXPECTED: Login Succeeded!

# Run oc-mirror v2 — full mirror to mirror-registry (sole airgap target, Phase 25.2)
# Note: --v2 (double dash) is mandatory; -v2 (single dash) is not recognised
# CA trust comes from ~/.config/containers/certs.d/${MIRROR_REGISTRY}/ca.crt (set in A-0)
oc-mirror \
  --config ~/coco-pattern/airgap/imageset-config-4.22.yaml \
  docker://${MIRROR_REGISTRY} \
  --dest-tls-verify=true \
  --workspace file://$HOME/oc-mirror-workspace \
  --v2 \
  2>&1 | tee -a "$LOG"

echo "B-2: oc-mirror complete at $(date)" 2>&1 | tee -a "$LOG"
```

> **Wait for oc-mirror to complete before proceeding to B-3.**
> Output is visible live in this window. Switch windows with `Ctrl-b <number>` while it runs.
> Expected completion: 3-4 hours.
> oc-mirror v2 is resumable — re-running the same command skips already-mirrored content.
>
> **Cosign signature failures:** Intel, HashiCorp, and NVIDIA images on
> `registry.connect.redhat.com` lack cosign `.sig` manifests. The
> `no-sigstore-certified.yaml` config (created in Phase 0-1 step h2) disables
> sigstore attachment lookups for these vendors, so oc-mirror handles them normally.
>
> **Transient failures (fixed by re-running):**
> `multicluster-engine/hive-rhel9` is 600MB+ and reliably times out on the first oc-mirror run
> (`context deadline exceeded` during blob upload). When hive-rhel9 times out, oc-mirror also
> skips `mce-operator-bundle` entirely — this cascades to: MCE CSV not installed → MCH stuck
> at Installing → ACM policy controller never starts → `credential` secret never created →
> trustee KbsConfig blocks forever.
> **If B-3 shows hive-rhel9 or mce-operator-bundle MISSING: re-run the B-2 oc-mirror command.**
> oc-mirror resumes from the workspace cache and retries only what failed — do NOT skip to Phase C.

### B-3: Post-Mirror Verification

```bash
echo "=== B-3: Post-Mirror Verification ===" 2>&1 | tee -a "$LOG"

# Count cluster-resources YAML files (expect ~9: IDMS, ITMS, CatalogSources, signatures)
ls ~/oc-mirror-workspace/working-dir/cluster-resources/*.yaml 2>&1 | tee -a "$LOG"
COUNT=$(ls ~/oc-mirror-workspace/working-dir/cluster-resources/*.yaml | wc -l)
echo "cluster-resources count: $COUNT (expected ~10)" 2>&1 | tee -a "$LOG"

# Paginate through full registry catalog — v2/_catalog returns max 100 repos per page
# CRITICAL: do NOT use a bare curl; with 270+ repos the first page misses everything past repo 100
echo "Spot-checking key repos in local-registry (paginated):" 2>&1 | tee -a "$LOG"
python3 - << 'PYEOF' 2>&1 | tee -a "$LOG"
import json, urllib.request, urllib.error, base64, os

creds = base64.b64encode(b"init:" + open(os.path.expanduser("~/.coco-pattern/mirror-registry-password"), "rb").read().strip()).decode()
headers = {"Authorization": f"Basic {creds}"}

repos = []
last = ""
while True:
    url = f"https://${MIRROR_REGISTRY}/v2/_catalog?n=100{f'&last={last}' if last else ''}"
    req = urllib.request.Request(url, headers=headers)
    ctx = __import__("ssl").create_default_context()
    ctx.load_verify_locations(os.path.expanduser("~/mirror-registry-certs/ca.crt"))
    try:
        with urllib.request.urlopen(req, context=ctx) as r:
            page = json.loads(r.read()).get("repositories", [])
    except Exception as e:
        print(f"ERROR: {e}"); break
    repos.extend(page)
    if len(page) < 100: break
    last = page[-1]

print(f"Total repos: {len(repos)}")
checks = [
    ("openshift/release-images", "OCP release images"),
    ("openshift/release",        "OCP release components"),
    ("validatedpatterns/clustergroup", "clustergroup chart"),
    ("community-operator-pipeline-prod/patterns-operator", "patterns-operator"),
    ("hashicorp/vault",          "Vault"),
    ("intel/intel-tdx-dcap-operator", "Intel TDX DCAP"),
    ("multicluster-engine/hive-rhel9", "MCE hive (large — timeout risk; re-run oc-mirror if missing)"),
    ("multicluster-engine/mce-operator-bundle", "MCE bundle (skipped by oc-mirror if hive timed out)"),
    ("build-of-trustee/trustee-rhel9", "Trustee"),
    ("multicluster-engine/hive-rhel9", "MCE Hive"),
    ("openshift-sandboxed-containers/osc-cloud-api-adaptor-rhel9", "CoCo cloud-api-adaptor"),
]
for repo, label in checks:
    status = "OK" if repo in repos else "MISSING"
    print(f"  {status}  {label} ({repo})")
PYEOF

# Verify IDMS files cover expected namespaces
echo "IDMS namespace coverage:" 2>&1 | tee -a "$LOG"
grep "${MIRROR_REGISTRY}" ~/oc-mirror-workspace/working-dir/cluster-resources/idms-oc-mirror.yaml | wc -l | xargs -I{} echo "  idms-oc-mirror.yaml: {} mirror entries" | tee -a "$LOG"
# idms-manual-mirrors.yaml no longer needed — oc-mirror generates IDMS for Intel/Hashicorp
# when registries.d/no-sigstore-certified.yaml is in place

echo "B-3: Post-mirror verification complete at $(date)" 2>&1 | tee -a "$LOG"
```

### B-3a: Manual Mirror — ELIMINATED

> **No longer needed.** The `no-sigstore-certified.yaml` registries.d config
> (Phase 0-1 step h2) disables sigstore attachment lookups for Intel, HashiCorp,
> and NVIDIA on `registry.connect.redhat.com`. oc-mirror now mirrors all images
> successfully and generates IDMS entries for them automatically.
>
> **ITMS (tag-based mirrors)** for `registry.connect.redhat.com/intel` and
> `/hashicorp` are still needed — oc-mirror only generates IDMS (digest-based).
> The supplementary ITMS lives at `airgap/itms-manual-mirrors.yaml` and is applied
> automatically by `airgap-post-install.sh` in D-1.

```bash
echo "=== B-3a: Verify supplementary ITMS in repo ===" | tee -a "$LOG"
cat ~/coco-pattern/airgap/itms-manual-mirrors.yaml 2>&1 | tee -a "$LOG"
# EXPECTED: ImageTagMirrorSet covering registry.connect.redhat.com/intel and /hashicorp
```

---

## PHASE C: Cluster Install (~35 min)

### C-1: Generate Configs and Build ISO

> labctl now generates the fake gateway directly (172.25.53.254) instead of `route-type: blackhole`,
> and embeds wipe-disks.ign into the ISO via `coreos-installer iso ignition embed`. No manual
> patching or separate openshift-install call needed.

```bash
echo "=== C-1: Generate Configs and Build ISO ===" 2>&1 | tee -a "$LOG"
source ~/.envrc

# ── labctl (APAC lab-specific) ───────────────────────────────────────────────
# labctl is an internal APAC lab tool that reads node configuration from an
# XLSX file and generates OCP agent-based install configs with the correct
# NIC, iDRAC, and network settings for this lab environment.
#
# For other environments, replace labctl generate with:
#   openshift-install agent create image --dir <output-dir>
# and mount the ISO via your BMC virtual media interface manually.
# ─────────────────────────────────────────────────────────────────────────────
labctl generate \
  --node node-02 \
  --xlsx "$HOME/APAC Technology Lab Details.xlsx" \
  --ocp-version 42208 \
  --output-dir ~/node-02-airgap-output \
  --mirror-resources ~/oc-mirror-workspace/working-dir/cluster-resources \
  --additional-trust-bundle ~/combined-ca-bundle.pem \
  --http-serve-path $HOME/public_html/ \
  2>&1 | tee -a "$LOG"

# Verify: fake gateway present, no blackhole, ISO built and served
grep "172.25.53.254" ~/node-02-airgap-output/agent-config.yaml 2>&1 | tee -a "$LOG" && \
  ! grep "blackhole" ~/node-02-airgap-output/agent-config.yaml && \
  echo "PASS: fake gateway in agent-config, no blackhole" 2>&1 | tee -a "$LOG"
ls -lh ~/public_html/node-02-42208.iso 2>&1 | tee -a "$LOG" && \
  echo "PASS: ISO present at http serve path" 2>&1 | tee -a "$LOG"

echo "C-1: Config generation and ISO build complete at $(date)" 2>&1 | tee -a "$LOG"
```


### C-3: Mount ISO via iDRAC

```bash
echo "=== C-3: Mount ISO via iDRAC ===" 2>&1 | tee -a "$LOG"
source ~/.envrc

# ── labctl (APAC lab-specific) ───────────────────────────────────────────────
# labctl is an internal APAC lab tool that reads node configuration from an
# XLSX file and generates OCP agent-based install configs with the correct
# NIC, iDRAC, and network settings for this lab environment.
#
# For other environments, replace labctl generate with:
#   openshift-install agent create image --dir <output-dir>
# and mount the ISO via your BMC virtual media interface manually.
# ─────────────────────────────────────────────────────────────────────────────
labctl idrac mount-iso \
  --node node-02 \
  --xlsx "$HOME/APAC Technology Lab Details.xlsx" \
  --iso-url "http://user-jump.int.apac-tech-lab.net/~chbutler/node-02-42208.iso" \
  2>&1 | tee -a "$LOG"

echo "C-3: ISO mounted at $(date)" 2>&1 | tee -a "$LOG"
```

### C-4: Wait for Install (~30 min)

```bash
tmux new-window -n "cluster-install"   # new window within the deploy session
eval "$(tmux showenv -g LOG)"; eval "$(tmux showenv -g MIRROR_REGISTRY)"; eval "$(tmux showenv -g GIT_SERVER)"

echo "=== C-4: Wait for Install ===" 2>&1 | tee -a "$LOG"
cd ~/node-02-airgap-output/42208_build

~/ocp_42208_bin/openshift-install agent wait-for install-complete \
  --dir . \
  --log-level info \
  2>&1 | tee -a "$LOG"

echo "C-4: Install complete at $(date)" 2>&1 | tee -a "$LOG"
```

> **Wait for install to complete before proceeding to C-5.**
> Expected log line: `Install complete!` and `Access the OpenShift web-console here:`
> Switch windows with `Ctrl-b <number>` while waiting.

### C-5: Health Check

```bash
echo "=== C-5: Health Check ===" 2>&1 | tee -a "$LOG"

# Find the build directory (changes per run)
BUILD_DIR=$(ls -td ~/node-02-airgap-output/4*_build* 2>/dev/null | head -1)
echo "Build dir: $BUILD_DIR" 2>&1 | tee -a "$LOG"

export KUBECONFIG="${BUILD_DIR}/auth/kubeconfig"
echo "KUBECONFIG=$KUBECONFIG" | tee -a "$LOG"

oc get clusterversion 2>&1 | tee -a "$LOG"
# EXPECTED: VERSION 4.22.8, STATUS Available
oc get nodes 2>&1 | tee -a "$LOG"
# EXPECTED: node-02 Ready

echo "C-5: Health check complete at $(date)" 2>&1 | tee -a "$LOG"
```

### C-6: Set KUBECONFIG

```bash
echo "=== C-6: Set KUBECONFIG ===" 2>&1 | tee -a "$LOG"

# The build directory name changes per run — set it from the actual output
BUILD_DIR=$(ls -td ~/node-02-airgap-output/4*_build* 2>/dev/null | head -1)
export KUBECONFIG="${BUILD_DIR}/auth/kubeconfig"

echo "export KUBECONFIG=${BUILD_DIR}/auth/kubeconfig" >> ~/.envrc
echo "KUBECONFIG set to: $KUBECONFIG" 2>&1 | tee -a "$LOG"

# Verify
oc whoami 2>&1 | tee -a "$LOG"
# EXPECTED: system:admin

echo "C-6: KUBECONFIG configured at $(date)" 2>&1 | tee -a "$LOG"
```

---

## PHASE D: Bootstrap and Pattern Deploy (~25 min)

### D-1: Run airgap-post-install.sh

> `airgap-post-install.sh` handles all of the following in one pass:
> - Disables OperatorHub default catalogs
> - Applies CatalogSources from oc-mirror cluster-resources (deleting stale ones)
> - Applies ALL oc-mirror cluster-resources: IDMS, ITMS, ClusterCatalog (OLM v1), signature ConfigMap
> - Applies supplementary IDMS (`idms-manual-mirrors.yaml` — intel/hashicorp, created in B-3a)
> - Applies supplementary ITMS (`airgap/itms-manual-mirrors.yaml` — intel/hashicorp, from repo)
> - Patches `mirrorSourcePolicy: NeverContactSource` on all IDMS entries (prevents internet fallback)
> - Configures the git HTTP server and patterns-operator-config ConfigMap

```bash
echo "=== D-1: airgap-post-install.sh ===" 2>&1 | tee -a "$LOG"
cd ~/coco-pattern

# MIRROR_REGISTRY was set in A-0; confirm it is still set
echo "MIRROR_REGISTRY=$MIRROR_REGISTRY" | tee -a "$LOG"

scripts/airgap-post-install.sh 2>&1 | tee -a "$LOG"

# Verify catalog pods are Running before proceeding to D-2
echo "--- CatalogSource pods ---" 2>&1 | tee -a "$LOG"
oc get pods -n openshift-marketplace 2>&1 | tee -a "$LOG"
# EXPECTED: 3 pods Running (redhat, certified, community operator indexes)

echo "D-1: airgap-post-install complete at $(date)" 2>&1 | tee -a "$LOG"
```

### D-1.5: Wait for MCO if airgap-post-install.sh patched any IDMS/ITMS

> **This step is now automated.** `airgap-post-install.sh` (step 3b/3c) patches `NeverContactSource`
> on all IDMS and ITMS objects — including the bootstrap `image-digest-mirror` IDMS created by
> `labctl` at cluster install time. If any objects were patched, MCO re-renders `registries.conf`.
> On SNO this triggers a **node reboot (~5 min)**. Check the script output for
> `"MCO will re-render registries.conf"` and wait for the node to recover before proceeding.

```bash
# If airgap-post-install.sh printed a reboot warning, wait here:
echo "=== D-1.5: Wait for node if MCO re-rendered ===" 2>&1 | tee -a "$LOG"
until oc get node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' \
  2>/dev/null | grep -q True; do
  echo "  Node not Ready yet — $(date)" | tee -a "$LOG"
  sleep 15
done
echo "Node Ready at $(date)" 2>&1 | tee -a "$LOG"
oc get nodes 2>&1 | tee -a "$LOG"
```

### D-2: Enable routingViaHost and Wait for MCO

```bash
echo "=== D-2: Enable routingViaHost ===" 2>&1 | tee -a "$LOG"

oc patch network.operator.openshift.io cluster --type merge \
  -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true}}}}}' \
  2>&1 | tee -a "$LOG"

echo "Waiting for MCO to complete (expect 5-10 min including reboot)..." 2>&1 | tee -a "$LOG"
while true; do
  STATUS=$(oc get mcp master -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null)
  UPDATING=$(oc get mcp master -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null)
  echo "STATUS: $(date) — MCO Updated=$STATUS Updating=$UPDATING" 2>&1 | tee -a "$LOG"
  [ "$STATUS" = "True" ] && [ "$UPDATING" = "False" ] && echo "MCO complete" 2>&1 | tee -a "$LOG" && break
  sleep 30
done

echo "D-2: routingViaHost enabled at $(date)" 2>&1 | tee -a "$LOG"
```

### D-3: Prepare Secrets on Disk

```bash
echo "=== D-3: Prepare Secrets ===" 2>&1 | tee -a "$LOG"
cd ~/coco-pattern

make cache-keys 2>&1 | tee -a "$LOG"
make cache-registry-ca 2>&1 | tee -a "$LOG"
./scripts/gen-secrets.sh 2>&1 | tee -a "$LOG"

# Strip trailing newline from mirror-registry-password.
# load-bootstrap reads this file verbatim via the values-secret.yaml path: field and
# the Ansible role does not strip whitespace. A trailing \n causes Helm to send
# "password\n" to the registry, which never matches the htpasswd hash → 401.
printf '%s' "$(cat ~/.coco-pattern/mirror-registry-password)" \
  > ~/.coco-pattern/mirror-registry-password
echo "mirror-registry-password length: $(wc -c < ~/.coco-pattern/mirror-registry-password) bytes (expected 24, no newline)" \
  2>&1 | tee -a "$LOG"

echo "D-3: Secrets prepared at $(date)" 2>&1 | tee -a "$LOG"
```

### D-4: Launch Pattern Deploy

```bash
tmux new-window -n "pattern-deploy"   # new window within the deploy session
eval "$(tmux showenv -g LOG)"; eval "$(tmux showenv -g MIRROR_REGISTRY)"; eval "$(tmux showenv -g GIT_SERVER)"

echo "=== D-4: Pattern Deploy ===" 2>&1 | tee -a "$LOG"
cd ~/coco-pattern

# Verify git remote and branch before deploy
git remote get-url origin 2>&1 | tee -a "$LOG"
# MUST: ${GIT_SERVER}/coco-pattern.git
git branch --show-current 2>&1 | tee -a "$LOG"
# MUST: dev/airgap-testing

./pattern.sh make install \
  2>&1 | tee -a "$LOG"

echo "D-4: pattern.sh complete at $(date)" 2>&1 | tee -a "$LOG"
```

> **Immediately switch to your main window and start D-5.** `Ctrl-b <number>` to switch.
> D-5 runs in parallel — it loops waiting for vp-gitops to appear, then fires automatically.
> **Do not wait** — if ArgoCD comes up before D-5 completes it will try to pull charts without credentials.
> MCO reboots during kata deployment are normal — not a failure signal.

### D-5: Inject CA + Load Bootstrap Secrets

> **Start this immediately after launching D-4** from the main tmux window.
> D-5 internally waits for `vp-gitops` to exist — start it now so it fires the moment ArgoCD is ready.
> If you delay, ArgoCD may come up and fail to pull VP OCI Helm charts before credentials are loaded.
>
> Steps D-5 performs once vp-gitops appears:
> 1. Inject mirror-registry private CA into ArgoCD's TLS trust store
> 2. `make load-bootstrap` — pre-seeds ArgoCD with mirror-registry OCI Helm credentials
>    (from the `bootstrap_secrets` block in values-secret.yaml; no vault required)
> 3. Hard-refresh ArgoCD so it pulls chart manifests from mirror-registry immediately

```bash
echo "=== D-5: ArgoCD CA + Bootstrap Secrets ===" 2>&1 | tee -a "$LOG"
cd ~/coco-pattern

# Wait for ArgoCD (vp-gitops namespace)
echo "Waiting for vp-gitops namespace..." 2>&1 | tee -a "$LOG"
until oc get ns vp-gitops &>/dev/null; do sleep 10; done
echo "vp-gitops active at $(date)" 2>&1 | tee -a "$LOG"

# Wait for repo-server deployment to exist before patching
until oc get deployment vp-gitops-repo-server -n vp-gitops &>/dev/null; do sleep 10; done

# Inject mirror-registry CA into ArgoCD TLS trust.
# mirror-registry uses the lab private CA — provide the chain so ArgoCD verifies properly.
# Note: CA cert contains literal newlines which must be escaped for JSON; use Python to build patch.
echo "Injecting mirror-registry CA into argocd-tls-certs-cm..." 2>&1 | tee -a "$LOG"
python3 -c "
import json, subprocess, sys
ca = open('$HOME/mirror-registry-certs/ca.crt').read()
import os; mreg_host = os.environ.get('MIRROR_REGISTRY','MIRROR_REGISTRY_HOST:8443').split(':')[0]
patch = json.dumps({'data': {mreg_host: ca}})
r = subprocess.run(['oc','patch','configmap','argocd-tls-certs-cm','-n','vp-gitops','--type','merge','-p',patch], capture_output=True, text=True)
print(r.stdout or r.stderr)
sys.exit(r.returncode)
" 2>&1 | tee -a "$LOG"

# Restart ALL vp-gitops pods to pick up the new CA and any secret changes.
# repo-server uses the CA for Helm registry login; other components may cache certs.
echo "Rolling all vp-gitops deployments..." 2>&1 | tee -a "$LOG"
oc get deployments -n vp-gitops --no-headers -o name 2>/dev/null | \
  while read dep; do oc rollout restart "$dep" -n vp-gitops 2>&1 | tee -a "$LOG"; done

# Wait for repo-server specifically before loading secrets (it handles Helm OCI auth)
oc rollout status deployment/vp-gitops-repo-server -n vp-gitops --timeout=120s \
  2>&1 | tee -a "$LOG"

# Load bootstrap secrets — creates ArgoCD OCI Helm repo secret for mirror-registry.
# This uses values-secret.yaml bootstrap_secrets section; runs before vault init.
# IMPORTANT: mirror-registry-password must have no trailing newline (fixed in D-3).
# A trailing \n causes Helm to send "password\n" → registry rejects with 401.
echo "Loading bootstrap secrets (ArgoCD OCI Helm repo auth)..." 2>&1 | tee -a "$LOG"
make load-bootstrap 2>&1 | tee -a "$LOG"

# Verify the secret was created and password has correct length (no trailing newline)
oc get secret mirror-registry-helm-oci -n vp-gitops 2>&1 | tee -a "$LOG"
# EXPECTED: mirror-registry-helm-oci   Opaque   ...
PASS_LEN=$(oc get secret mirror-registry-helm-oci -n vp-gitops \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d | wc -c)
echo "mirror-registry-helm-oci password length: ${PASS_LEN} bytes (expected: same as mirror-registry-password file)" \
  2>&1 | tee -a "$LOG"
if [ "${PASS_LEN}" -gt 24 ]; then
  echo "WARN: password may have trailing newline — patch the secret:" 2>&1 | tee -a "$LOG"
  echo "  MREG_PASS=\$(cat ~/.coco-pattern/mirror-registry-password | tr -d '\\n')" 2>&1 | tee -a "$LOG"
  echo "  oc create secret generic mirror-registry-helm-oci -n vp-gitops \\" 2>&1 | tee -a "$LOG"
  echo "    --from-literal=type=helm --from-literal=enableOCI=true \\" 2>&1 | tee -a "$LOG"
  echo "    --from-literal=url=${MIRROR_REGISTRY}/validatedpatterns \\" 2>&1 | tee -a "$LOG"
  echo "    --from-literal=name=mirror-registry-charts \\" 2>&1 | tee -a "$LOG"
  echo "    --from-literal=username=init --from-literal=password=\"\$MREG_PASS\" \\" 2>&1 | tee -a "$LOG"
  echo "    --dry-run=client -o yaml | oc apply -f -" 2>&1 | tee -a "$LOG"
fi

# Trigger hard refresh — ArgoCD now has CA trust + credentials for mirror-registry
oc annotate applications.argoproj.io coco-pattern-baremetal -n vp-gitops \
  argocd.argoproj.io/refresh=hard --overwrite 2>&1 | tee -a "$LOG"

sleep 30

# Verify child apps are appearing
echo "--- ArgoCD child apps ---" 2>&1 | tee -a "$LOG"
oc get applications.argoproj.io -A --no-headers 2>/dev/null | \
  awk '{print $2, $4, $5}' | column -t 2>&1 | tee -a "$LOG"
# EXPECTED: vault, acm, kyverno, openshift-external-secrets, storage, etc. are listed

echo "D-5: ArgoCD configured at $(date)" 2>&1 | tee -a "$LOG"
```

### D-6: Wait for Vault and Load Secrets

```bash
echo "=== D-6: Wait for Vault + Load Secrets ===" 2>&1 | tee -a "$LOG"
cd ~/coco-pattern

while true; do
  INIT=$(oc exec -n vault vault-0 -- vault status -format=json 2>/dev/null | \
    python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('initialized',''))" 2>/dev/null || echo "")
  SEALED=$(oc exec -n vault vault-0 -- vault status -format=json 2>/dev/null | \
    python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('sealed',''))" 2>/dev/null || echo "")
  echo "STATUS: $(date) — Vault init=$INIT sealed=$SEALED" 2>&1 | tee -a "$LOG"
  [ "$INIT" = "True" ] && [ "$SEALED" = "False" ] && echo "Vault ready" 2>&1 | tee -a "$LOG" && break
  sleep 15
done

./pattern.sh make load-secrets 2>&1 | tee -a "$LOG"
# EXPECTED: 10 secrets injected

echo "D-6: Secrets loaded at $(date)" 2>&1 | tee -a "$LOG"
```

---

## PHASE E: DCAP and TDX Attestation (~10-15 min)

### E-1: Verify DCAP Readiness

```bash
echo "=== E-1: DCAP Readiness ===" 2>&1 | tee -a "$LOG"

oc get pods -n intel-dcap-operator-system -l app=intel-tdx-qgs --no-headers \
  2>&1 | tee -a "$LOG"
# EXPECTED: NAME   2/2   Running
# NOTE: QGS DaemonSet runs in intel-dcap-operator-system, not openshift-operators

oc get secrets -n intel-dcap-operator-system -l type=platform-data --no-headers \
  2>&1 | tee -a "$LOG"
# EXPECTED: 1 secret (name is the QE ID hex string)

echo "E-1: DCAP readiness verified at $(date)" 2>&1 | tee -a "$LOG"
```

### E-2: QGS Socket Port Verification

> `charts/all/baremetal/templates/vsock-mco.yaml` deploys a MachineConfig drop-in at
> `/etc/kata-containers/kata-tdx/config.d/96-kata-kernel-config` that sets `socket_port=0`.
> Verify that the drop-in exists and the effective port is 0. The base `configuration.toml`
> may still show 4050 — that is overridden by the drop-in, which kata reads last.

```bash
echo "=== E-2: QGS Socket Port Verification ===" 2>&1 | tee -a "$LOG"

NODE=$(oc get nodes -o name | head -1)
echo "Checking node: $NODE" 2>&1 | tee -a "$LOG"

# Check the drop-in file (authoritative — overrides configuration.toml)
DROP_IN=$(oc debug $NODE -- chroot /host bash -c \
  "cat /etc/kata-containers/kata-tdx/config.d/96-kata-kernel-config 2>/dev/null" \
  2>/dev/null)
echo "Drop-in content: $DROP_IN" 2>&1 | tee -a "$LOG"

if echo "$DROP_IN" | grep -q "socket_port=0"; then
  echo "PASS: socket_port=0 in drop-in — QGS will use unix socket" 2>&1 | tee -a "$LOG"
else
  echo "FAIL: drop-in missing or socket_port not 0 — record as DEV-1 in DEVIATIONS.md" 2>&1 | tee -a "$LOG"
  echo "  See Appendix A.3 for the fallback sed command (apply ONLY after recording DEV-1)" 2>&1 | tee -a "$LOG"
fi

echo "E-2: QGS socket port verification complete at $(date)" 2>&1 | tee -a "$LOG"
```

> **If verification fails (DEV-1):** The MachineConfig drop-in was not applied — check that
> `oc get mc | grep kata-tdx` shows a MachineConfig with the drop-in content.
> See Appendix Section A.3 for the temporary sed fallback. Record in DEVIATIONS.md.

### E-3: PCK Registration — pcsclient.py cache (ALWAYS REQUIRED, INTERACTIVE)

> **This step is ALWAYS required** — even when QE IDs match and cached PCK cert files exist.
> `pcsclient.py cache` does two things: (1) provisions the PCK certificate secret so QGS can
> generate quotes, and (2) populates the local cache with **QeIdentity and TcbInfo** that
> `collect-dcap-collateral.sh` reads in E-4. Skipping this step leaves `qeidentity` empty in
> `platform_collaterals.json`, causing KBS to fail attestation with
> `"collateral JSON error: invalid type: string "", expected struct QeIdentity"`.
>
> **This step must be run interactively** — `pcsclient.py` prompts for the Intel PCS API key
> via `getpass` and cannot be automated via SSH pipe (see `UPSTREAM-ISSUES-INTEL-DCAP.md` Issue 3).

```bash
echo "=== E-3: PCK Registration (INTERACTIVE — run in tmux) ===" 2>&1 | tee -a "$LOG"
cd ~/pck-registration

# Step 1: Generate platform_list.json from cluster platform-data secrets
echo "Generating platform_list.json..." 2>&1 | tee -a "$LOG"
oc get secrets -o json -n intel-dcap-operator-system -l 'type=platform-data' \
  | jq '[.items[] | .data | map_values(@base64d)]' > platform_list.json
echo "platform_list.json: $(wc -l < platform_list.json) lines" 2>&1 | tee -a "$LOG"

# Step 2: Compare QE IDs — cache reuse check (informational only)
CLUSTER_QE_ID=$(oc get secrets -n intel-dcap-operator-system -l type=platform-data \
  --no-headers -o custom-columns=NAME:.metadata.name | head -1)
CACHED_QE_ID=$(ls cache/*_0000 2>/dev/null | head -1 | xargs basename 2>/dev/null | sed 's/_0000//')
echo "Cluster QE ID: $CLUSTER_QE_ID" 2>&1 | tee -a "$LOG"
echo "Cached QE ID:  $CACHED_QE_ID" 2>&1 | tee -a "$LOG"
if [ "$CLUSTER_QE_ID" = "$CACHED_QE_ID" ] && [ -n "$CACHED_QE_ID" ]; then
  echo "QE ID MATCH — PCK cert cache reusable. Still must run pcsclient.py cache for QeIdentity." \
    2>&1 | tee -a "$LOG"
else
  echo "QE ID MISMATCH — record as DEV-2 in DEVIATIONS.md" 2>&1 | tee -a "$LOG"
fi

# Step 3: Run pcsclient.py cache INTERACTIVELY
# Will prompt: "Please input ApiKey for Intel PCS:" — paste your key.
# Populates cache/ with PCK certs AND QeIdentity/TcbInfo for E-4.
echo "STOP: Run the following command interactively in this tmux window:" 2>&1 | tee -a "$LOG"
echo ""
echo "  python3 ~/confidential-computing.tee.dcap/tools/PcsClientTool/pcsclient.py cache \\"
echo "    -i platform_list.json \\"
echo "    -e 8760 \\"
echo "    -t early"
echo ""
echo "Enter API key when prompted, then press Enter."
echo "When complete, continue to Step 4 below."

# Step 4: Apply PCK cert secret to cluster and restart QGS
# (Run after pcsclient.py cache completes)
for f in cache/*_0000; do
  qe_id=$(basename "$f" _0000)
  echo "Applying PCK cert for QE ID: $qe_id" 2>&1 | tee -a "$LOG"
  oc create secret generic "${qe_id}-pck" --from-file=certificate="$f" \
    -n intel-dcap-operator-system --dry-run=client -o yaml | oc apply -f - \
    2>&1 | tee -a "$LOG"
done
oc delete pod -n intel-dcap-operator-system -l app=intel-tdx-qgs \
  2>&1 | tee -a "$LOG"

echo "E-3: PCK registration complete at $(date)" 2>&1 | tee -a "$LOG"
```

### E-4: Collect DCAP Collateral and Firmware Reference Values

> **Must run AFTER E-3** — `collect-dcap-collateral.sh` calls `pcsclient.py fetch` which reads
> from the local cache populated by `pcsclient.py cache` in E-3. Running E-4 before E-3
> produces `platform_collaterals.json` with `qeidentity: ""` — KBS will fail attestation.

```bash
echo "=== E-4: Collect DCAP Collateral + Firmware Refvals ===" 2>&1 | tee -a "$LOG"
cd ~/coco-pattern

make collect-dcap-collateral 2>&1 | tee -a "$LOG"

# Verify QeIdentity is populated (must be >100 chars)
python3 -c "
import json, os
c = json.load(open(os.path.expanduser('~/.coco-pattern/dcap-offline/platform_collaterals.json')))
qi = c.get('collaterals', {}).get('qeidentity', '')
print('qeidentity length:', len(qi), '— PASS' if len(qi) > 100 else '— FAIL: re-run E-3 first')
" 2>&1 | tee -a "$LOG"

make collect-firmware-refvals 2>&1 | tee -a "$LOG"

echo "E-4: DCAP collateral and refvals collected at $(date)" 2>&1 | tee -a "$LOG"
```

### E-5: Reload Secrets

```bash
echo "=== E-5: Reload Secrets ===" 2>&1 | tee -a "$LOG"
cd ~/coco-pattern

./pattern.sh make load-secrets 2>&1 | tee -a "$LOG"
# EXPECTED: 10 secrets injected (including DCAP collateral and firmware refvals)

echo "E-5: Secrets reloaded at $(date)" 2>&1 | tee -a "$LOG"
```

---

## PHASE F: Verification and Pass/Fail (~10 min)

### F-1: Wait for initdata ConfigMaps

```bash
echo "=== F-1: Wait for initdata ConfigMaps ===" 2>&1 | tee -a "$LOG"

while true; do
  COUNT=$(oc get configmap -n imperative -l coco.io/type=initdata --no-headers 2>/dev/null | wc -l)
  echo "STATUS: $(date) — initdata ConfigMaps: $COUNT/2" 2>&1 | tee -a "$LOG"
  [ "$COUNT" -ge 2 ] && echo "Initdata ready" 2>&1 | tee -a "$LOG" && break
  sleep 30
done

echo "F-1: initdata ConfigMaps ready at $(date)" 2>&1 | tee -a "$LOG"
```

### F-2: Bounce Workload Pods

```bash
echo "=== F-2: Bounce Workload Pods ===" 2>&1 | tee -a "$LOG"

oc delete pods --all -n hello-openshift --force --grace-period=0 \
  2>&1 | tee -a "$LOG"
oc delete pods --all -n kbs-access --force --grace-period=0 \
  2>&1 | tee -a "$LOG"

echo "Waiting 90 seconds for pods to restart..." 2>&1 | tee -a "$LOG"
sleep 90

echo "F-2: Pods bounced at $(date)" 2>&1 | tee -a "$LOG"
```

### F-3: Verify Pods Running

```bash
echo "=== F-3: Verify Pods Running ===" 2>&1 | tee -a "$LOG"

echo "--- hello-openshift ---" 2>&1 | tee -a "$LOG"
oc get pods -n hello-openshift 2>&1 | tee -a "$LOG"
# EXPECTED: 3/3 Running (standard, insecure-policy, secure)

echo "--- kbs-access ---" 2>&1 | tee -a "$LOG"
oc get pods -n kbs-access 2>&1 | tee -a "$LOG"
# EXPECTED: kbs-access-curl 1/1, kbs-access-sealed 1/1 (or similar)

echo "F-3: Pod status captured at $(date)" 2>&1 | tee -a "$LOG"
```

### F-4: Verify KBS Attestation

```bash
echo "=== F-4: Verify KBS Attestation ===" 2>&1 | tee -a "$LOG"

oc logs deployment/trustee-deployment -n trustee-operator-system -c kbs --tail=20 \
  2>&1 | tee -a "$LOG"
# EXPECTED: POST /attest 200, GET /resource 200

echo "F-4: KBS attestation verified at $(date)" 2>&1 | tee -a "$LOG"
```

### F-5: Verify Image Sources

```bash
echo "=== F-5: Verify Image Sources (all from mirror-registry) ===" 2>&1 | tee -a "$LOG"

for ns in hello-openshift kbs-access trustee-operator-system; do
  echo "--- $ns ---" 2>&1 | tee -a "$LOG"
  oc get pods -n $ns -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.containers[*].image}{"\n"}{end}' \
    2>&1 | tee -a "$LOG"
done

# Flag any image not from mirror-registry or the internal OCP registry
echo "Upstream refs (should be empty):" 2>&1 | tee -a "$LOG"
oc get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' 2>/dev/null \
  | grep -v "${MIRROR_REGISTRY}\|image-registry.openshift-image-registry" \
  | sort | uniq \
  2>&1 | tee -a "$LOG" || echo "All images from expected registries" | tee -a "$LOG"

echo "F-5: Image sources verified at $(date)" 2>&1 | tee -a "$LOG"
```

### F-6: Verify ArgoCD Apps

```bash
echo "=== F-6: Verify ArgoCD Apps ===" 2>&1 | tee -a "$LOG"

oc get applications.argoproj.io -n vp-gitops \
  2>&1 | tee -a "$LOG"
# EXPECTED: All apps Synced+Healthy

APP_COUNT=$(oc get applications.argoproj.io -n vp-gitops --no-headers 2>/dev/null | wc -l)
HEALTHY_COUNT=$(oc get applications.argoproj.io -n vp-gitops --no-headers 2>/dev/null \
  | grep -c "Synced.*Healthy" || echo "0")
echo "ArgoCD: $HEALTHY_COUNT/$APP_COUNT apps Synced+Healthy" 2>&1 | tee -a "$LOG"

echo "F-6: ArgoCD status captured at $(date)" 2>&1 | tee -a "$LOG"
```

### F-7: Phase 24 Validation Checks (D-07)

> **These checks validate that Phase 24 cleanup decisions did not break the deploy.**
> Record results in DEVIATIONS.md if any check fails.

```bash
echo "=== F-7: Phase 24 Validation Checks (D-07) ===" 2>&1 | tee -a "$LOG"

# Check 1: scripts/deprecated/ contains exactly 3 scripts, none were invoked during deploy
echo "--- Check 1: scripts/deprecated/ contents ---" 2>&1 | tee -a "$LOG"
ls -la ~/coco-pattern/scripts/deprecated/ 2>&1 | tee -a "$LOG"
DEPRECATED_COUNT=$(ls ~/coco-pattern/scripts/deprecated/ | wc -l)
echo "Deprecated script count: $DEPRECATED_COUNT (expected: 3)" 2>&1 | tee -a "$LOG"
if [ "$DEPRECATED_COUNT" = "3" ]; then
  echo "PASS: Exactly 3 deprecated scripts present (none removed, none invoked)" 2>&1 | tee -a "$LOG"
else
  echo "DEVIATION: Record deprecated count mismatch in DEVIATIONS.md" 2>&1 | tee -a "$LOG"
fi

# Check 2: values-baremetal-airgap.yaml is the 2-line global overlay (D-05 / Phase 24 C-05)
echo "--- Check 2: values-baremetal-airgap.yaml shape ---" 2>&1 | tee -a "$LOG"
cat ~/coco-pattern/values-baremetal-airgap.yaml 2>&1 | tee -a "$LOG"
OVERLAY_LINES=$(grep -c "global\." ~/coco-pattern/values-baremetal-airgap.yaml 2>/dev/null || echo "0")
echo "global.* lines in overlay: $OVERLAY_LINES (expected: 2)" 2>&1 | tee -a "$LOG"
grep -q "global.catalogSource" ~/coco-pattern/values-baremetal-airgap.yaml && \
  grep -q "global.catalogSourceNamespace" ~/coco-pattern/values-baremetal-airgap.yaml && \
  echo "PASS: 2-line global catalogSource overlay active" 2>&1 | tee -a "$LOG" || \
  echo "DEVIATION: values-baremetal-airgap.yaml does not match expected 2-line shape" 2>&1 | tee -a "$LOG"

# Check 3: mirror-registry is still present and serving
echo "--- Check 3: mirror-registry health ---" 2>&1 | tee -a "$LOG"
curl -sk --cacert ~/mirror-registry-certs/ca.crt \
  https://${MIRROR_REGISTRY}/v2/_catalog \
  2>&1 | tee -a "$LOG"
MIRROR_STATUS=$?
if [ "$MIRROR_STATUS" = "0" ]; then
  echo "PASS: mirror-registry accessible at ${MIRROR_REGISTRY}" 2>&1 | tee -a "$LOG"
else
  echo "DEVIATION: mirror-registry not accessible — record in DEVIATIONS.md" 2>&1 | tee -a "$LOG"
fi

# Check 4: Record whether VP hybrid images required mirror-registry or pulled from Quay alone
echo "--- Check 4: VP hybrid image source ---" 2>&1 | tee -a "$LOG"
echo "Review B-4 log output: did airgap-post-install.sh WARN about VP images?" 2>&1 | tee -a "$LOG"
grep "WARN.*VP\|WARN.*patterns-operator\|mirror-registry" "$LOG" | head -5 2>&1 | tee -a "$LOG"
echo "If WARNs appeared → mirror-registry still needed (record in DEVIATIONS.md as Phase 26 prerequisite confirmed)" 2>&1 | tee -a "$LOG"
echo "If no WARNs → VP images served from Quay alone (record as Phase 26 milestone: mirror-registry removable)" 2>&1 | tee -a "$LOG"

echo "F-7: Phase 24 validation checks complete at $(date)" 2>&1 | tee -a "$LOG"
```

### F-8: Pass/Fail Criteria Table

Fill in the ACTUAL column after running the above steps. Record any failures in DEVIATIONS.md.

```bash
echo "=== F-8: Pass/Fail Summary ===" 2>&1 | tee -a "$LOG"

# Collect key status values for the summary table
echo "patterns-operator CSV:" 2>&1 | tee -a "$LOG"
oc get csv -n openshift-operators -l operators.coreos.com/patterns-operator.openshift-operators \
  --no-headers 2>&1 | tee -a "$LOG"

echo "Vault status:" 2>&1 | tee -a "$LOG"
oc exec -n vault vault-0 -- vault status 2>&1 | tee -a "$LOG"

echo "MCH status:" 2>&1 | tee -a "$LOG"
oc get mch -A 2>&1 | tee -a "$LOG"

echo "=== Run Complete: $(date) ===" 2>&1 | tee -a "$LOG"
```

**Pass/Fail Criteria Reference Table:**

| Criterion | Expected | Actual |
|-----------|----------|--------|
| patterns-operator CSV Succeeded | Via OLM from mirror-registry community catalog | |
| Pattern CR reconciles | targetRepo = HTTP git URL (not GitHub) | |
| Vault init without manual SA creation | Sync-wave fix still working | |
| 15/15 (or current count) ArgoCD apps Synced+Healthy | All green | |
| KBS attestation affirming | POST /attest 200 | |
| KBS resource delivery | GET /resource 200 | |
| hello-openshift 3/3 Running | standard + insecure-policy + secure | |
| kbs-access-curl Running | Uses privileged SCC SA | |
| kbs-access-sealed Running | Uses Secret volume | |
| secret.txt contains KBS resource | Fetched via CDH from KBS | |
| All images from mirror-registry | No upstream refs | |
| MCH Running | ACM + MCE healthy | |
| QGS socket_port=0 WITHOUT manual sed | D-06 — MCO fix working (new row) |
| No mirrorSourcePolicy conflicts after D-1.5 | PASS: all IDMS/ITMS have NeverContactSource (new row) | |
| scripts/deprecated/ untouched — 3 files, none invoked | D-07 — no deprecated scripts called (new row) | |
| 2-line global catalogSource overlay active in values-baremetal-airgap.yaml | D-07 — Phase 24 C-05 migration active (new row) | |
| mirror-registry serving VP hybrid images | D-07 — confirms two-registry still needed OR single-registry milestone | |

**Known Warnings (not failures):**

| Warning | Explanation |
|---------|-------------|
| VP hybrid images WARN in airgap-post-install.sh | Images pre-pushed to mirror-registry. Script cannot re-push (already there). |
| insights operator unavailable | Expected in airgap — cannot reach console.redhat.com |
| clusterversion Error reconciling | Caused by insights operator. Cosmetic. |
| MCO reboots during kata deployment | Normal behavior — not a failure signal |

---

## APPENDIX

### A.1: DEVIATIONS.md Template (D-04)

Copy this template to `~/coco-pattern/DEVIATIONS.md` at the start of the run.
Add a new `## DEV-N` section for each deviation discovered during execution.

```markdown
# Run 25 Deviations

**Run date:** YYYY-MM-DD
**Operator:** chbutler
**Log file:** ~/coco-pattern/logs/run-25-YYYYMMDD.log

## Format

Each deviation entry:
- What happened (observation)
- What was done (action taken)
- Impact on Phase 26 cleanup decisions

---

## DEV-1: [Title — fill in if QGS socket_port fix not automatic]

**Phase step:** E-2
**What happened:** [e.g., socket_port was 4050 instead of 0 in kata-tdx/configuration.toml]
**What was done:** [e.g., applied fallback sed — see Appendix A.3]
**Impact on Phase 26:** [e.g., MCO-layer QGS fix not working; Phase 26 must investigate and automate]

---

## DEV-2: [Title — fill in if QE ID mismatch required pcsclient.py]

**Phase step:** E-3
**What happened:** [e.g., cluster QE ID c0560e9b019a720a6a09149ec518bbe1 did not match cached ID]
**What was done:** [e.g., ran pcsclient.py interactively to generate new PCK material]
**Impact on Phase 26:** [e.g., hypothesis disproved — SGX platform reset required; investigate trigger]

---

## DEV-N: [Add more entries as needed]

**Phase step:**
**What happened:**
**What was done:**
**Impact on Phase 26:**
```

### A.2: local-registry API Reference

Container name: `local-registry` (podman). Image: `docker.io/library/registry:2`.
Storage: `~/local-registry` (host bind mount, owned by chbutler).
Config: `~/mirror-registry-config/config.yml`. Certs: `~/mirror-registry-certs/`.
Auth: htpasswd (`~/mirror-registry-config/htpasswd`). Username: `init`.
Password file: `~/.coco-pattern/mirror-registry-password` (600, git-ignored).

```bash
# List all repos
curl -sk -u "$MREG_USER:$MREG_PASS" https://${MIRROR_REGISTRY}/v2/_catalog

# List tags for a repo
curl -sk -u "$MREG_USER:$MREG_PASS" https://${MIRROR_REGISTRY}/v2/<repo>/tags/list
```

TLS: self-signed cert — use `-sk` (skip TLS verify) or `--cacert ~/mirror-registry-certs/ca.crt`

Decommission: `podman stop local-registry && rm -rf ~/local-registry/* && podman start local-registry`

SELinux note: htpasswd file requires `container_file_t` label. If recreating, run:
`chcon -t container_file_t ~/mirror-registry-config/htpasswd`

CA trust for container tools (podman, oc-mirror, skopeo):
```bash
mkdir -p ~/.config/containers/certs.d/${MIRROR_REGISTRY}
cp ~/mirror-registry-certs/ca.crt ~/.config/containers/certs.d/${MIRROR_REGISTRY}/ca.crt
```
This is idempotent and is run automatically in A-0. It enables `--dest-tls-verify=true` in oc-mirror
and removes the need for `--tls-verify=false` in podman login.

### A.3: QGS Socket Port Fallback (Deviation Footnote Only)

> **Apply ONLY if E-2 verification fails and DEV-1 is recorded in DEVIATIONS.md.**
> This is a deviation fallback — not a normal execution step.

```bash
# FALLBACK ONLY (if E-2 fails) — record as DEV-1 first
echo "Applying QGS socket port fallback sed (DEV-1 deviation)..." 2>&1 | tee -a "$LOG"
NODE=$(oc get nodes -o name | head -1)
oc debug $NODE -- chroot /host bash -c \
  "sed -i 's/tdx_quote_generation_service_socket_port = 4050/tdx_quote_generation_service_socket_port = 0/' \
  /etc/kata-containers/kata-tdx/configuration.toml" \
  2>&1 | tee -a "$LOG"
echo "Fallback sed applied — record in DEVIATIONS.md as DEV-1" 2>&1 | tee -a "$LOG"
```

### A.4: Post-Run Log Retrieval

After the run completes, Claude SSHes in to analyze the log:

```bash
# Claude retrieves log from jump host
ssh chbutler@user-jump.int.apac-tech-lab.net "cat ~/coco-pattern/logs/run-25-*.log"
```

The operator does not need to gzip, commit, or serve the log file. Claude reads it directly via SSH.
After analysis, commit DEVIATIONS.md to coco-gsd:

```bash
# On jump host — commit DEVIATIONS.md back
cd ~/coco-pattern
git add DEVIATIONS.md
git commit -m "docs(run-25): record run deviations"
git push origin dev/airgap-testing

# Then in coco-gsd
cd ~/coco-gsd
cp ../coco-pattern/DEVIATIONS.md .planning/phases/25-manual-logged-jump-host-deploy-runbook/RUN-25-DEVIATIONS.md
git add .planning/phases/25-manual-logged-jump-host-deploy-runbook/RUN-25-DEVIATIONS.md
git commit -m "docs(25): import run-25 deviations log"
git push origin main
```

### A.5: Environment Variable Quick-Reference

Set these before starting the run:

```bash
export LOG=~/coco-pattern/logs/run-25-YYYYMMDD.log
export MREG_USER=init
export MREG_PASS=$(cat ~/.coco-pattern/mirror-registry-password)
```

Auto-set during run:
```bash
export KUBECONFIG=<set in C-6 from build dir>
export MIRROR_REGISTRY=MIRROR_REGISTRY_HOST:8443
```

Persistent in `~/.envrc`:
```bash
export LABCTL_IDRAC_USER=chbutler
export LABCTL_IDRAC_PASSWORD="..."
```

### A.6: Add local-registry to pull-secret.json

The cluster's global pull-secret (embedded in `install-config.yaml` by labctl) must include
credentials for MIRROR_REGISTRY_HOST:8443. Without this, cluster nodes cannot pull images redirected
by the IDMS files generated by oc-mirror.

Run once after initial auth setup, or if the registry password is regenerated:

```bash
MREG_PASS=$(cat ~/.coco-pattern/mirror-registry-password)
MREG_AUTH=$(echo -n "init:$MREG_PASS" | base64 -w 0)

python3 - <<'EOF'
import json, os

ps_path = os.path.expanduser("~/pull-secret.json")
with open(ps_path) as f:
    ps = json.load(f)

import base64
mreg_pass = open(os.path.expanduser("~/.coco-pattern/mirror-registry-password")).read().strip()
mreg_auth = base64.b64encode(f"init:{mreg_pass}".encode()).decode()

ps["auths"]["${MIRROR_REGISTRY}"] = {
    "auth": mreg_auth,
    "username": "init",
    "password": mreg_pass
}

with open(ps_path, "w") as f:
    json.dump(ps, f, indent=2)

print("Done. Registries in pull-secret.json:")
for k in ps["auths"]:
    print(f"  {k}")
EOF
```

> **When to re-run:** Only if `~/.coco-pattern/mirror-registry-password` changes (password
> regeneration). The htpasswd auth survives `rm -rf ~/local-registry/*` (A-4) — only image
> data is wiped, not auth config.
