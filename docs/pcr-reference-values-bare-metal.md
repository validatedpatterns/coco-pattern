# Collecting PCR Reference Values on Bare Metal for RVPS Attestation

## Overview

The Trustee attestation service uses the Reference Value Provider Service (RVPS) to verify that a confidential VM is running the expected software stack. RVPS compares measurements from the TEE attestation quote against pre-registered reference values. On Azure, these values are populated automatically. On bare metal, they must be collected manually and pushed to Vault.

This document covers the collection of vTPM PCR values for bare-metal TDX deployments, **excluding PCR8** (init data), which is computed separately by the `init-data-gzipper.yaml` imperative playbook.

## What Gets Measured

### PCR Registers Used by RVPS

The trustee chart's RVPS policy (`rvps-values-policies.yaml`) consumes these PCR values:

| PCR | Contents | Source |
|-----|----------|--------|
| PCR03 | Boot loader configuration | `pcr-stash` secret |
| PCR08 | Init data (CoCo-specific) | `initdata` ConfigMap (computed by `init-data-gzipper.yaml`) |
| PCR09 | Boot loader code | `pcr-stash` secret |
| PCR11 | BitLocker access control / TPM event log | `pcr-stash` secret |
| PCR12 | Boot events | `pcr-stash` secret |

PCR08 is excluded from this procedure because it represents the hash of the CoCo init data TOML, which changes with each deployment configuration. It is handled by the `ansible/init-data-gzipper.yaml` playbook, which renders the init data template, computes `sha256(zero_pcr || sha256(initdata.toml))`, and stores the result in the `imperative/initdata` ConfigMap as `PCR8_HASH`.

### TDX RTMR to PCR Mapping

For TDX on bare metal, the vTPM inside the confidential VM maps measurements to PCR registers. The underlying TDX hardware uses Runtime Measurement Registers (RTMRs):

| RTMR | Contents | Corresponding PCRs |
|------|----------|---------------------|
| MRTD | TD build-time measurement (firmware) | N/A (separate field in quote) |
| RTMR[0] | TDVF configuration, ACPI tables | PCR 0-1 |
| RTMR[1] | OS kernel, boot parameters, initrd | PCR 4-7 |
| RTMR[2] | OS applications, IMA measurements | PCR 8-15 |
| RTMR[3] | Reserved | N/A |

## Collection Methods

### Method 1: From a Running Confidential VM (Recommended)

Launch a confidential container pod, exec into it, and read the vTPM PCR values. This gives you the actual measurements for your specific firmware + kernel + configuration.

**Prerequisites:**

- A working CoCo deployment with kata runtime installed
- `tpm2-tools` available in the guest (or use a debug pod)

**Steps:**

1. Launch a confidential pod:

   ```bash
   oc run pcr-collector --image=registry.access.redhat.com/ubi9/ubi:latest \
     --restart=Never --overrides='{"spec":{"runtimeClassName":"kata-cc"}}' \
     -- sleep 3600
   ```

1. Install tpm2-tools inside the pod:

   ```bash
   oc exec pcr-collector -- dnf install -y tpm2-tools
   ```

1. Read PCR values (SHA-256 bank):

   ```bash
   oc exec pcr-collector -- tpm2_pcrread sha256:3,9,11,12
   ```

   Example output:

   ```text
   sha256:
     3 : 0x3D458CFE55CC03EA1F443F1562BEE8DF30100AB2E1C4B6E5FE4568E7B0E6745A
     9 : 0x96A18E5C5E3E9AEC7FE5B8A1C6A02E8D6A4E8C6B3E9A7F5B2D4C8E1A3F6B9D2
     11: 0x0000000000000000000000000000000000000000000000000000000000000000
     12: 0x0000000000000000000000000000000000000000000000000000000000000000
   ```

1. Clean up:

   ```bash
   oc delete pod pcr-collector
   ```

### Method 2: Pre-Calculation with tdx-measure

The [virtee/tdx-measure](https://github.com/virtee/tdx-measure) tool computes expected TDX measurement registers offline from firmware and kernel binaries, without requiring a running TD.

**Install:**

```bash
cargo install tdx-measure
```

**Usage:**

Create a metadata JSON file describing your boot components:

```json
{
  "firmware": "/path/to/OVMF.fd",
  "kernel": "/path/to/vmlinuz",
  "initrd": "/path/to/initrd.img",
  "cmdline": "console=ttyS0",
  "memory_mb": 4096,
  "vcpus": 2
}
```

Compute all measurements:

```bash
tdx-measure metadata.json --direct-boot true --json
```

Compute platform-only (MRTD + RTMR0, excludes kernel/initrd):

```bash
tdx-measure metadata.json --platform-only --json
```

Compute runtime-only (RTMR1 + RTMR2, kernel + initrd):

```bash
tdx-measure metadata.json --runtime-only --json
```

**Note:** You need to extract the firmware (OVMF/TDVF), kernel, and initrd images from your OpenShift node. These can be found in the kata containers payload.

### Method 3: From the Attestation Quote

If you have a running deployment with attestation disabled (`global.coco.secured: false`), you can capture the raw attestation quote and extract measurements:

1. Deploy with `bypassAttestation: true` in the trustee configuration
2. Launch a confidential pod
3. The attestation agent logs the quote contents — extract PCR values from the quote structure
4. Use these values as your reference baseline

## Pushing Values to Vault

Once you have collected PCR values, push them to Vault in the format expected by the `pcrs-eso` ExternalSecret:

```bash
# Format: JSON object with measurements.sha256.pcrNN keys
oc exec -n vault vault-0 -- vault kv put secret/hub/pcrStash \
  json='{
    "measurements": {
      "sha256": {
        "pcr03": "<PCR03_HEX_VALUE>",
        "pcr09": "<PCR09_HEX_VALUE>",
        "pcr11": "<PCR11_HEX_VALUE>",
        "pcr12": "<PCR12_HEX_VALUE>"
      }
    }
  }'
```

The `pcrs-eso` ExternalSecret will then sync this into a `pcr-stash` Kubernetes secret in the `trustee-operator-system` namespace. The RVPS policy (`rvps-values-policies.yaml`) reads from this secret to populate the `rvps-reference-values` ConfigMap.

## Pipeline Summary

```text
tpm2_pcrread (inside CoCo pod)
  |
  v
Vault: secret/data/hub/pcrStash    (pcr03, pcr09, pcr11, pcr12)
  |
  v (ExternalSecret: pcrs-eso)
K8s Secret: pcr-stash               (trustee-operator-system)
  |
  v (ACM Policy: rvps-policy)
ConfigMap: rvps-reference-values     (trustee-operator-system)
  |
  v
Attestation Service RVPS            (compares against TD quote)
```

PCR8 follows a separate path:

```text
ansible/init-data-gzipper.yaml
  |
  v
ConfigMap: initdata                  (imperative namespace)
  |                                  contains: INITDATA, PCR8_HASH
  v (ACM Policy: rvps-policy)
ConfigMap: rvps-reference-values     (merged with pcr-stash values)
```

## References

- [Red Hat: How to deploy confidential containers on bare metal](https://developers.redhat.com/articles/2025/02/19/how-deploy-confidential-containers-bare-metal)
- [Red Hat: Introducing Confidential Containers Trustee](https://www.redhat.com/en/blog/introducing-confidential-containers-trustee-attestation-services-solution-overview-and-use-cases)
- [Intel: Runtime Integrity Measurement and Attestation in a Trust Domain](https://www.intel.com/content/www/us/en/developer/articles/community/runtime-integrity-measure-and-attest-trust-domain.html)
- [virtee/tdx-measure](https://github.com/virtee/tdx-measure) - Pre-calculate TDX measurements offline
- [CoCo Attestation Service RVPS docs](https://github.com/confidential-containers/attestation-service/blob/main/docs/rvps.md)
- [CoCo Attestation Policies](https://confidentialcontainers.org/docs/attestation/policies/)
