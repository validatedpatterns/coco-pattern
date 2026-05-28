# Firmware Reference Values for Bare Metal Attestation

This guide explains how to collect firmware reference values for bare metal confidential computing deployments (Intel TDX / AMD SEV-SNP).

## Overview

Firmware reference values are cryptographic measurements of the Trusted Computing Base (TCB) components:

- **Intel TDX**: `mr_td` (OVMF code hash), `rtmr_1` (kernel/initrd), `rtmr_2` (cmdline), `xfam` (extended features)
- **AMD SEV-SNP**: `snp_launch_measurement` (firmware/kernel/initrd hash)

These values are used by the KBS attestation policy to verify that confidential workloads are running on approved firmware with expected security properties.

## Prerequisites

### 1. Veritas Tool

The [veritas](https://github.com/confidential-containers/veritas) tool collects attestation evidence from confidential VMs.

**Installation:** Veritas is automatically installed inside the collection pod by the script. No local installation required.

**Version requirement**: 0.2.0 or later

### 2. Bare Metal Cluster Access

You need:

- A running bare metal cluster with Intel TDX or AMD SEV-SNP hardware
- KataConfig deployed and in Ready state
- At least one kata pod successfully running (proves TEE is functional)
- `oc` CLI logged in to the cluster
- `jq` installed locally

### 3. Local Tools

```bash
# Check prerequisites
command -v oc && echo "✓ oc CLI installed"
command -v jq && echo "✓ jq installed"
oc whoami && echo "✓ Logged in to cluster"
```

## Workflow

The firmware collection workflow is fully automated via a single command:

### Step 1: Collect Firmware Reference Values

```bash
# From the coco-pattern repository root:
make collect-firmware-refvals
```

This command:

1. Launches a kata pod with `RuntimeClass: kata-cc`
2. Installs veritas inside the pod
3. Collects firmware measurements from the TEE
4. Transforms output to RVPS format (JSON with arrays)
5. Saves to `~/.coco-pattern/firmware-reference-values.json`
6. Cleans up the pod

**Output format** (`~/.coco-pattern/firmware-reference-values.json`):

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
- Hash values are lowercase hex strings (SHA-384 = 96 hex chars for TDX/SNP firmware)
- Empty arrays `[]` mean "not available" - attestation will skip that check
- Only populated fields for the detected TEE type (TDX or SNP)

### Step 2: Enable in values-secret.yaml

Uncomment the `firmwareReferenceValues` section in `~/values-secret-coco-pattern.yaml`:

```yaml
- name: firmwareReferenceValues
  vaultPrefixes:
  - hub
  fields:
  - name: json
    path: ~/.coco-pattern/firmware-reference-values.json
```

### Step 3: Load Secrets to Vault

```bash
make load-secrets
```

The validated patterns framework reads `values-secret-coco-pattern.yaml` and pushes firmware values to Vault at `secret/data/hub/firmwareReferenceValues`.

### Step 4: Verify Upload

```bash
# Check the secret was written to Vault
vault kv get secret/hub/firmwareReferenceValues
```

Expected output shows a single `json` key containing the full JSON object.

### Step 5: Deploy/Sync KBS

If the KBS cluster is already running:

```bash
# Force ExternalSecret to re-sync from Vault
oc delete externalsecret firmware-refvals-eso -n trustee-operator-system

# Verify the secret synced
oc get secret firmware-reference-values -n trustee-operator-system

# Check RVPS ConfigMap contains firmware entries
oc get configmap rvps-reference-values -n trustee-operator-system -o yaml
```

If deploying fresh:

```bash
make install
```

The RVPS will automatically reload reference values from the `rvps-reference-values` ConfigMap.

## Multi-OCP-Version Support

Different OpenShift versions may have different firmware measurements due to kernel/initrd changes. To support multiple versions:

1. **Collect from each version:**

   ```bash
   # OCP 4.18 cluster
   make collect-firmware-refvals

   # OCP 4.19 cluster
   make collect-firmware-refvals-merge
   ```

2. **The merge automatically deduplicates:**

   The `--merge` flag (used by `collect-firmware-refvals-merge`) reads the existing file, unions the arrays, and deduplicates:

   ```json
   {
     "mr_td": ["<4.18-value>", "<4.19-value>"],
     "rtmr_2": ["<4.18-kernel>", "<4.19-kernel>"]
   }
   ```

3. **Load merged values to Vault:**

   ```bash
   make load-secrets
   ```

The attestation policy uses `in` checks - a pod passes if its measurement matches **any** value in the array.

## Advanced Options

The collection script supports several options:

```bash
# Merge with existing file
./scripts/collect-firmware-refvals.sh --merge

# Use different namespace for collection pod
./scripts/collect-firmware-refvals.sh --namespace my-namespace

# Override output file
./scripts/collect-firmware-refvals.sh --output /custom/path/firmware.json

# Use different RuntimeClass (for peer-pods/Azure)
./scripts/collect-firmware-refvals.sh --runtime-class kata-remote

# Use custom base image
./scripts/collect-firmware-refvals.sh --pod-image myregistry.io/custom-ubi9:latest

# Show all options
./scripts/collect-firmware-refvals.sh --help
```

## Known Limitations (Veritas Gaps)

As of veritas 0.2.0, the following are **not** collected and must be added manually if needed:

### 1. TCB Version Numbers

Veritas does not extract minimum TCB version numbers (bootloader, microcode, SNP, TEE). These are available in the attestation evidence but not in the veritas JSON output.

**Workaround:** Extract from attestation quotes manually if needed. Add to the JSON file as:

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

### Collection script fails to launch pod

**Symptom:** `oc apply` fails or pod stuck in Pending

**Check:**

- RuntimeClass `kata-cc` exists: `oc get runtimeclass kata-cc`
- KataConfig is Ready: `oc get kataconfig kata-config`
- Node has sufficient resources

### Veritas collection fails

**Symptom:** `veritas collect` returns empty or errors

**Check:**

1. Pod is using correct RuntimeClass (kata-cc for bare metal)
2. Pod is actually running on bare metal hardware (not Azure peer-pods)
3. TEE device exists inside pod: `oc exec <pod> -- ls /dev/tdx_guest` (TDX) or `ls /dev/sev` (SNP)
4. Veritas installed correctly: `oc exec <pod> -- veritas --version`

### KBS attestation still passes without firmware values

**Expected behavior:** The attestation policy has backwards-compatible fallback rules. If no firmware reference values are in RVPS, the policy only checks `init_data`.

To **enforce** firmware, remove the fallback rules from `attestation-policy.yaml`:

```rego
# Remove these "hardware := 2 if count(query_reference_value(...)) == 0" rules
```

### Hash mismatch after cluster upgrade

**Cause:** Kernel/firmware updated, changing rtmr_2 or mr_td

**Fix:** Re-collect firmware values from upgraded cluster, merge into existing file:

```bash
make collect-firmware-refvals-merge
make load-secrets
```

## SHA-256 vs SHA-384

You may notice different hash algorithms in different contexts:

- **init_data TOML**: SHA-256 (CoCo initdata spec, used for PCR8 extend)
- **Bare metal TDX firmware**: SHA-384 (Intel TDX architecture requirement)
- **Bare metal SNP firmware**: SHA-384 (AMD SEV-SNP architecture requirement)
- **Azure vTPM PCRs**: SHA-256

These are **correct** - they're different mechanisms at different layers. The attestation policy checks these independently.

## Security Considerations

### Threat Model

Firmware reference values protect against:

- Unauthorized firmware modifications (malicious OVMF, compromised bootloader)
- Kernel tampering (different kernel than expected)
- Debug mode enabled (allows memory inspection via hypervisor)

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
- [AMD SEV-SNP Attestation Spec](https://www.amd.com/en/developer/sev.html)
- [Trustee Attestation Policy Reference](https://github.com/openshift/trustee-operator/tree/main/config/templates)
