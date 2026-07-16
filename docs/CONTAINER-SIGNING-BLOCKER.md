# Container Signing Policy Enforcement - Upstream Blocker

**Status**: ⛔ BLOCKED - Waiting for upstream fix  
**Issue**: Red Hat container image signature verification fails with sigstore policies  
**Upstream PR**: [guest-components#1398](https://github.com/confidential-containers/guest-components/pull/1398)

## Summary

Container image signature verification for Red Hat images (registry.redhat.io, registry.access.redhat.com) is currently **not working** in Confidential Containers due to a bug in the `image-rs` sigstore implementation.

**Current Configuration**: `securityPolicyFlavour: "insecure"` (no signature verification)  
**Target Configuration**: `securityPolicyFlavour: "redhat-secure-sigstore"` (blocked)

## Root Cause

**Bug**: image-rs does not base64-decode the `keyData` field for cosign/sigstore signatures.

**Location**: `image-rs/src/signature/policy/cosign/mod.rs` line 69

**Current code**:

```rust
(Some(key_data), None) => key_data.as_bytes().to_vec(),  // ❌ Wrong: treats base64 string as raw bytes
```

**Expected code**:

```rust
(Some(key_data), None) => {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(key_data)?  // ✅ Correct: decode base64 first
}
```

**Impact**: The cryptographic verifier receives base64-encoded text instead of decoded PEM key bytes, causing all signature verification attempts to fail with "rejected by sigstoreSigned rule".

## Evidence

### Podman Works (Golang containers/image)

```bash
# Test on RHEL 10.2 with identical policy
podman pull --signature-policy=policy.json \
  registry.redhat.io/ubi9/httpd-24:latest

# Result: ✅ SUCCESS
# - Signature found in registry
# - Verification passed
# - Image pulled successfully
```

### image-rs Fails (Rust rewrite)

```bash
# CoCo pod with identical policy
Image: registry.redhat.io/ubi9/httpd-24@sha256:68a91ff...
Policy: kbs:///default/security-policy/redhat-secure-sigstore
Key: Embedded base64-encoded PEM public key

# Result: ❌ FAIL
# Error: Image policy rejected: Denied by policy: rejected by `sigstoreSigned` rule
# Pod status: CreateContainerError
```

**The error message proves repository matching works** - if matching failed, the error would be "no matching policy" not "rejected by sigstoreSigned rule".

## Upstream Fix Status

**PR**: [guest-components#1398](https://github.com/confidential-containers/guest-components/pull/1398)  
**Repository**: confidential-containers/guest-components  
**Component**: image-rs (used by attestation-agent in kata guest VMs)

**Required for**:

- Red Hat build of trustee-operator
- OpenShift Sandboxed Containers
- Confidential Containers on OpenShift

**Waiting on**:

1. PR merge to guest-components
2. Release of updated guest-components version
3. Integration into Red Hat build of trustee
4. Update of kata guest image with fixed image-rs

## Infrastructure Ready for Future Enablement

All required infrastructure is **already deployed** and tested:

### ✅ Deployed Components

1. **Sigstore public key**
   - Source: `/etc/pki/sigstore/SIGSTORE-redhat-release3` from RHEL 10.2
   - Key ID: `4096R/E60D446E63405576` (issued 2024-09-20)
   - Location: `coco-pattern/keys/SIGSTORE-redhat-release3`

2. **KBS secret**
   - Secret: `sigstore-keys` in `trustee-operator-system` namespace
   - Field: `redhat-release3`
   - KBS URI: `kbs:///default/sigstore-keys/redhat-release3`

3. **Policy template**
   - Policy: `redhat-secure-sigstore` in `values-secret.yaml.template`
   - Type: `sigstoreSigned` with embedded `keyData`
   - Registries: `registry.redhat.io`, `registry.access.redhat.com`

4. **Makefile targets**
   - `make cache-sigstore-keys` - Cache key to `~/.coco-pattern/`

### ✅ Verified Working

**Podman verification successful** (2026-07-03):

- Platform: RHEL 10.2 jump host
- Image: registry.access.redhat.com/ubi9/ubi-minimal:latest
- Policy: sigstoreSigned with Red Hat sigstore key
- Result: Signature verification passed ✅

## Policy Configuration

### Current (Insecure)

```yaml
# values-global.yaml
global:
  coco:
    securityPolicyFlavour: "insecure"  # ⚠️ No signature verification
```

### Target (When Fix Lands)

```yaml
# values-global.yaml
global:
  coco:
    securityPolicyFlavour: "redhat-secure-sigstore"  # ✅ Sigstore verification
```

### Policy Details

```json
{
  "default": [{"type": "insecureAcceptAnything"}],
  "transports": {
    "docker": {
      "registry.redhat.io": [
        {
          "type": "sigstoreSigned",
          "keyData": "YXJ0aWZhY3RzIHRoYXQgYXJlIHNpZ3N0b3JlLWVuYWJsZWQuCi0tLS0tQkVHSU4gUFVCTElDIEtFWS0tLS0tCk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBMEFTeXVIMlRMV3ZCVXFQSFo0SXAKNzVnN0VuY0JrZ1FIZEpuanp4QVc1S1FUTWgvc2lCb0IvQm9TcnRpUE13bkNoYlRDblFPSVFlWnVEaUZuaHVKNwpNL0QzYjdKb1gwbTEyM05jQ1NuNjdtQWRqQmE2Qmc2a3VrWmdDUDRaVVplRVNhaldYL0VqeWxGY1JGT1hXNTdwClJEQ0VONDJKL2pZbFZxdCtnOStHcmtlcjhTejg2SDNsMHRicU9kamJ6L1Z4SFlod0YwY3RVTUhzeVZSRHEyUVAKdHF6TlhsbWxNaFMvUG9GcjZSNHUvN0hDbi9LK0xlZ2NPMmZBRk9iNDBLdktTS0tWRDZsZXdVWkVyaG9wMUNnSgpYakR0R21tTzlkR01GNzFtZjZIRWZhS1NkeStFRTZpU0YyQTJWdjlRaEJhd01pcTJrT3pFaUxnNG5BZEpUOHdnClpyTUFtUENxR0lzWE5HWjQvUStZVHd3bGNlM2dscWI1TDl0Zk5vekVkU1I5Tjg1REVTZlFMUUVkWTNDYWx3S00KQlQxT0VoRVgxd0hSQ1U0ZHJNT2VqNkJOVzBWdHNjR3RIbUNyczc0alBlemh3TlQ4eXBreVMrVDB6VDRUc3k2ZgpWWGtKOFlTSHllblN6TUIyT3AyYnZzRTNnclkrczc0V2hHOVVJQTZEQnhjVGllMTVOU3pLd2Z6YW9OV09EY0xGCnA3Qlk4YWFIRTJNcUZ4WUZYK0lianBrUVJmYWVRUXNvdURGZENrWEVGVmZQcGJEMmRrNkZsZWFNVFB1eXh0SVQKZ2pWRXRHUUsycUdDRkdpUUhGZDRoZlYrZUNBNjNKcm8xejB6b0JNNUJiSUlRMytlVkZ3dDNBbFpwNVVWd3I2ZApzZWNxa2kveXJtdjNZMGRxWjlWT24zVUNBd0VBQVE9PQotLS0tLUVORCBQVUJMSUMgS0VZLS0tLS0K",
          "signedIdentity": {"type": "matchRepository"}
        }
      ],
      "registry.access.redhat.com": [
        {
          "type": "sigstoreSigned",
          "keyData": "YXJ0aWZhY3RzIHRoYXQgYXJlIHNpZ3N0b3JlLWVuYWJsZWQuCi0tLS0tQkVHSU4gUFVCTElDIEtFWS0tLS0tCk1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBMEFTeXVIMlRMV3ZCVXFQSFo0SXAKNzVnN0VuY0JrZ1FIZEpuanp4QVc1S1FUTWgvc2lCb0IvQm9TcnRpUE13bkNoYlRDblFPSVFlWnVEaUZuaHVKNwpNL0QzYjdKb1gwbTEyM05jQ1NuNjdtQWRqQmE2Qmc2a3VrWmdDUDRaVVplRVNhaldYL0VqeWxGY1JGT1hXNTdwClJEQ0VONDJKL2pZbFZxdCtnOStHcmtlcjhTejg2SDNsMHRicU9kamJ6L1Z4SFlod0YwY3RVTUhzeVZSRHEyUVAKdHF6TlhsbWxNaFMvUG9GcjZSNHUvN0hDbi9LK0xlZ2NPMmZBRk9iNDBLdktTS0tWRDZsZXdVWkVyaG9wMUNnSgpYakR0R21tTzlkR01GNzFtZjZIRWZhS1NkeStFRTZpU0YyQTJWdjlRaEJhd01pcTJrT3pFaUxnNG5BZEpUOHdnClpyTUFtUENxR0lzWE5HWjQvUStZVHd3bGNlM2dscWI1TDl0Zk5vekVkU1I5Tjg1REVTZlFMUUVkWTNDYWx3S00KQlQxT0VoRVgxd0hSQ1U0ZHJNT2VqNkJOVzBWdHNjR3RIbUNyczc0alBlemh3TlQ4eXBreVMrVDB6VDRUc3k2ZgpWWGtKOFlTSHllblN6TUIyT3AyYnZzRTNnclkrczc0V2hHOVVJQTZEQnhjVGllMTVOU3pLd2Z6YW9OV09EY0xGCnA3Qlk4YWFIRTJNcUZ4WUZYK0lianBrUVJmYWVRUXNvdURGZENrWEVGVmZQcGJEMmRrNkZsZWFNVFB1eXh0SVQKZ2pWRXRHUUsycUdDRkdpUUhGZDRoZlYrZUNBNjNKcm8xejB6b0JNNUJiSUlRMytlVkZ3dDNBbFpwNVVWd3I2ZApzZWNxa2kveXJtdjNZMGRxWjlWT24zVUNBd0VBQVE9PQotLS0tLUVORCBQVUJMSUMgS0VZLS0tLS0K",
          "signedIdentity": {"type": "matchRepository"}
        }
      ]
    }
  }
}
```

The `keyData` field contains the Red Hat sigstore public key (release key 3) base64-encoded.

## Why GPG Signatures Don't Work Either

Red Hat dual-signs all container images:

1. **GPG signatures** - Stored on separate HTTPS lookaside servers
2. **Sigstore signatures** - Stored as OCI artifacts in the registry

**GPG approach blocked**: image-rs does not support HTTP/HTTPS for fetching signatures from lookaside servers (tracked in [image-rs#9](https://github.com/confidential-containers/image-rs/issues/9)).

**Sigstore approach blocked**: This base64-decode bug.

## Re-Enabling Signature Verification

When the upstream fix is available:

### 1. Verify Fix is Available

```bash
# Check guest-components release notes for the fix
# Confirm Red Hat trustee-operator includes updated image-rs
```

### 2. Update Configuration

```bash
cd ~/coco-pattern
git pull origin dev/phase1-modernization

# Edit values-global.yaml
# Change: securityPolicyFlavour: "insecure"
# To:     securityPolicyFlavour: "redhat-secure-sigstore"
```

### 3. Deploy Updated Pattern

```bash
export KUBECONFIG=~/node-02-output/421_build/auth/kubeconfig
./pattern.sh make install
```

### 4. Verify Signature Enforcement

```bash
# Delete confidential pod to force recreation
oc delete pod -n hello-openshift -l app=secure

# Check pod starts successfully
oc get pods -n hello-openshift -l app=secure

# Verify policy is active
oc get pod -n hello-openshift -l app=secure -o yaml | grep -A 5 init_data

# Should show: image_security_policy_uri = 'kbs:///default/security-policy/redhat-secure-sigstore'
```

### 5. Test with Unsigned Image

```bash
# Create test deployment with unsigned custom image
oc apply -n hello-openshift -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unsigned-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: unsigned-test
  template:
    metadata:
      labels:
        app: unsigned-test
    spec:
      runtimeClassName: kata
      containers:
      - name: test
        image: docker.io/library/nginx:latest  # Unsigned image
EOF

# Pod should FAIL with policy rejection
oc get pods -n hello-openshift -l app=unsigned-test
# Expected: CreateContainerError - Image policy rejected
```

If unsigned images are rejected and Red Hat images start successfully, signature verification is working.

## Timeline

| Date | Event |
|------|-------|
| 2026-07-03 | Bug identified, infrastructure deployed |
| 2026-07-04 | Reverted to insecure policy, documented blocker |
| TBD | guest-components PR #1398 merged |
| TBD | New guest-components release |
| TBD | Red Hat trustee-operator update |
| TBD | Re-enable signature verification |

## Related Documentation

- **Phase 6 Context**: `.planning/phases/06-container-signing-policy-enforcement/06-CONTEXT.md`
- **Phase 6 Blocker**: `.planning/phases/06-container-signing-policy-enforcement/06-BLOCKER.md` (in coco-gsd repository)
- **Sigstore Success**: `.planning/phases/06-container-signing-policy-enforcement/06-SIGSTORE-SUCCESS.md` (in coco-gsd repository)
- **Upstream PR**: [guest-components#1398](https://github.com/confidential-containers/guest-components/pull/1398)
- **image-rs Issue**: [image-rs issues](https://github.com/confidential-containers/image-rs/issues)

---

*Document created: 2026-07-04*  
*Infrastructure status: ✅ Ready*  
*Verification status: ⛔ Blocked by upstream*
