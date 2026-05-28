# Firmware Reference Values for Bare Metal Attestation

## Overview

Firmware reference values provide cryptographic measurements of the trusted computing base (TCB) for Intel TDX and AMD SEV-SNP confidential VMs running on bare metal. These values enable attestation policies to verify that workloads are running on known-good firmware with the expected security configuration.

Without firmware reference values, attestation only verifies the `init_data` (runtime configuration hash). With firmware values, the Key Broker Service (KBS) can enforce:

- **Hardware integrity**: Verify firmware measurements (MRTD, RTMRs, launch measurement)
- **TCB version**: Ensure minimum firmware/microcode versions
- **Security configuration**: Enforce debug-disabled mode

## Architecture

### Intel TDX Measurements

- **mr_td** (SHA-384): Initial contents of the TD (Trust Domain) - firmware + initial page tables
- **rtmr_1** (SHA-384): Guest firmware + bootloader measurements
- **rtmr_2** (SHA-384): Kernel + initrd measurements
- **xfam** (hex): Extended feature mask - CPU features available to the TD

### AMD SEV-SNP Measurements

- **snp_launch_measurement** (SHA-384): Hash of initial guest memory contents + VMSA
- **debug flag**: Policy bit indicating whether debug is allowed

### Hash Algorithm Clarification

Different layers use different hash algorithms - this is **correct and expected**:

| Layer | Algorithm | Why |
|-------|-----------|-----|
| init_data (OSC TOML) | SHA-256 | CoCo initdata spec, extends into vTPM PCR8 |
| TDX firmware (mr_td, rtmr_*) | SHA-384 | Intel TDX architecture requirement |
| SNP firmware (launch_measurement) | SHA-384 | AMD SEV-SNP architecture requirement |
| Azure vTPM PCRs | SHA-256 | TPM 2.0 default bank for virtual TPMs |

The attestation policy verifies each independently - there is no conflict.

## Prerequisites

### 1. Veritas Tool

Veritas is a Python tool for collecting reference values from confidential VMs. Install via pip:

```bash
pip install veritas-collectd
```

**Version requirement**: 0.2.0 or later

### 2. Bare Metal Cluster Access

You need:
- A running bare metal cluster with Intel TDX or AMD SEV-SNP hardware
- KataConfig deployed and in Ready state
- At least one kata pod successfully running (proves TEE is functional)

### 3. Vault Access

You need write access to the Vault instance at `secret/data/hub/firmwareReferenceValues`.

If using the pattern's default Vault setup:
```bash
# Get Vault root token from cluster
oc get secret -n vault vault-init -o jsonpath='{.data.root_token}' | base64 -d
```

## Workflow

### Step 1: Collect Reference Values from Kata Pod

Run a kata pod on the bare metal cluster and use veritas to extract firmware measurements:

```bash
# Create a test pod with kata-remote runtime
oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: firmware-collector
  namespace: default
spec:
  runtimeClassName: kata-remote
  containers:
  - name: busybox
    image: quay.io/quay/busybox:latest
    command: ["sleep", "3600"]
EOF

# Wait for pod to be Running
oc wait --for=condition=Ready pod/firmware-collector -n default --timeout=300s

# Exec into the pod and run veritas
oc exec -it firmware-collector -n default -- sh

# Inside the pod:
veritas collect --output /tmp/refvals.json
cat /tmp/refvals.json
exit

# Copy the reference values out
oc cp default/firmware-collector:/tmp/refvals.json ./refvals-$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' | tr ' ' '-').json
```

### Step 2: Transform to Vault Format

Veritas output format differs from what KBS expects. Use the provided script:

```bash
# In the coco-pattern repository root:
make push-firmware-refvals REFVALS_FILE=./refvals-*.json
```

This script:
1. Extracts firmware measurements from veritas JSON
2. Converts to the KBS/RVPS expected format (arrays of hex strings)
3. Pushes to Vault at `secret/data/hub/firmwareReferenceValues`

### Step 3: Vault Secret Format

The script creates a secret with this structure:

```json
{
  "mr_td": ["a1b2c3d4..."],
  "rtmr_1": ["e5f6a7b8..."],
  "rtmr_2": ["c9d0e1f2..."],
  "snp_launch_measurement": ["f3e4d5c6..."],
  "xfam": ["e742060000000000"]
}
```

**Key points:**
- Each field is an **array** of strings (supports multiple valid values)
- Hash values are lowercase hex strings (SHA-384 = 96 hex chars)
- Empty arrays `[]` mean "not available" - attestation will skip that check
- Missing keys are treated the same as empty arrays

### Step 4: Verify Upload

```bash
# Check the secret was written
vault kv get secret/hub/firmwareReferenceValues

# Expected output:
# ====== Data ======
# Key                        Value
# ---                        -----
# mr_td                      ["a1b2c3d4..."]
# rtmr_1                     ["e5f6a7b8..."]
# ...
```

### Step 5: Trigger KBS Sync

The trustee-chart creates an ExternalSecret that pulls from this Vault path. Force a sync:

```bash
# On the cluster with KBS deployed:
oc delete externalsecret firmware-refvals-eso -n trustee-operator-system

# Wait for it to recreate (ArgoCD sync-wave or manual re-apply)
# Verify the secret exists:
oc get secret firmware-reference-values -n trustee-operator-system
```

The RVPS will automatically reload reference values from the `rvps-reference-values` ConfigMap.

## Multi-OCP-Version Support

Different OpenShift versions may have different firmware measurements due to kernel/initrd changes. To support multiple versions:

1. **Collect from each version:**
   ```bash
   # OCP 4.18 cluster
   veritas collect --output refvals-ocp-4.18.json
   
   # OCP 4.19 cluster  
   veritas collect --output refvals-ocp-4.19.json
   ```

2. **Merge the arrays:**
   ```json
   {
     "mr_td": ["<4.18-value>", "<4.19-value>"],
     "rtmr_2": ["<4.18-kernel>", "<4.19-kernel>"]
   }
   ```

3. **Push merged values to Vault:**
   ```bash
   vault kv put secret/hub/firmwareReferenceValues \
     mr_td='["val1","val2"]' \
     rtmr_1='["val1","val2"]' \
     rtmr_2='["val1","val2"]'
   ```

The attestation policy uses `in` checks - a pod passes if its measurement matches **any** value in the array.

## Known Limitations (Veritas Gaps)

As of veritas 0.2.0, the following are **not** collected and must be added manually if needed:

### 1. TCB Version Numbers

Veritas does not extract minimum required TCB levels (e.g., SNP microcode version). To enforce:

```json
{
  "tcb_bootloader_min": "3",
  "tcb_snp_min": "20",
  "tcb_microcode_min": "115"
}
```

Then update the attestation policy to check:
```rego
input.snp.report.reported_tcb.bootloader >= tcb_bootloader_min
```

### 2. SNP Policy Bits

The SNP guest policy contains multiple flags (smt_allowed, migrate_ma, debug, etc.). Veritas reports the full policy word but does not break it into individual enforcement rules.

To enforce specific policy bits, add to attestation policy:
```rego
input.snp.report.policy.smt_allowed == false
input.snp.report.policy.debug == false
```

### 3. Container Image Measurements

Veritas does not measure the application container image digest. Image policy enforcement is handled separately via:
- Confidential Data Hub (CDH) pulling image from KBS
- Kyverno policies validating image signatures (cosign, Notary)

## Troubleshooting

### Veritas collection fails

**Symptom:** `veritas collect` returns empty or errors

**Check:**
1. Pod is using `kata-remote` RuntimeClass
2. Pod is actually running on bare metal (not Azure peer-pods)
3. TEE device exists: `ls /dev/tdx_guest` (TDX) or `ls /dev/sev` (SNP)

### KBS attestation still passes without firmware values

**Expected behavior:** The attestation policy has backwards-compatible fallback rules. If no firmware reference values are in RVPS, the policy only checks `init_data`.

To **enforce** firmware, remove the fallback rules from `attestation-policy.yaml`:
```rego
# Remove these "hardware := 2 if count(query_reference_value(...)) == 0" rules
```

### Hash mismatch after cluster upgrade

**Cause:** Kernel/firmware updated, changing rtmr_2 or mr_td

**Fix:** Re-collect firmware values from upgraded cluster, merge into Vault arrays

## Security Considerations

### Firmware Reference Values Are Sensitive

These values reveal the exact firmware/kernel configuration of your confidential cluster. Treat them as **confidential**:

- Store in Vault with ACLs restricting read access
- Do not commit to public Git repositories
- Rotate if disclosed (re-image nodes with different firmware if possible)

### Attestation Policy Trade-offs

Strict firmware enforcement provides stronger security but reduces operational flexibility:

| Policy | Security | Flexibility |
|--------|----------|-------------|
| init_data only | Medium | High - easy upgrades |
| init_data + firmware | High | Low - every kernel update requires reference value refresh |
| init_data + firmware + TCB min | Highest | Lowest - blocks old firmware entirely |

Choose the level appropriate for your threat model.

### Debug Mode

The attestation policy enforces `debug == false` for both TDX and SNP. Debug mode allows:
- Memory inspection via hypervisor
- Single-stepping the guest
- Extracting secrets from guest memory

**Production workloads must run with debug disabled.** If attestation fails due to debug mode, do not disable the check - fix the KataConfig to disable debug.

## References

- [Veritas Documentation](https://github.com/confidential-containers/veritas)
- [Intel TDX Attestation Spec](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-trust-domain-extensions.html)
- [AMD SEV-SNP Attestation Spec](https://www.amd.com/system/files/TechDocs/56860.pdf)
- [CoCo Attestation Architecture](https://github.com/confidential-containers/attestation-service)
