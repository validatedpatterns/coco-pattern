# Collecting Reference Values for Attestation

This guide explains how to collect firmware and PCR reference values for confidential computing deployments on both Azure and bare metal (Intel TDX / AMD SEV-SNP).

## Overview

Reference values are cryptographic measurements of the Trusted Computing Base (TCB). The Trustee attestation service compares these against evidence from running workloads to verify integrity.

| Platform | TEE | Measurements | Hash Algorithm |
|----------|-----|-------------|----------------|
| Azure | TDX (vTPM) | PCR03, PCR09, PCR11, PCR12 | SHA-256 |
| Azure | SNP (vTPM) | PCR03, PCR09, PCR11, PCR12 | SHA-256 |
| Bare metal | TDX | mr_td, rtmr_1, rtmr_2, xfam | SHA-384 |
| Bare metal | SNP | snp_launch_measurement | SHA-384 |

Both platforms use the [veritas](https://github.com/confidential-devhub/veritas) tool, packaged in the `quay.io/openshift_sandboxed_containers/coco-tools` container. No cluster access is required — veritas computes expected measurements from OCP release artifacts or the dm-verity image.

## Prerequisites

- `podman` installed and running
- `yq` and `jq` installed
- OpenShift pull secret at `~/pull-secret.json`
- For bare metal: OCP version of your cluster (auto-detected if `oc` is logged in)

## Collecting Reference Values

### Azure

```bash
# Collect PCR values from the dm-verity image
make collect-azure-refvals

# Or with explicit OSC version:
./scripts/collect-firmware-refvals.sh --platform azure --osc-version 1.12.0
```

Output: `~/.coco-pattern/measurements.json`

Veritas pulls the `osc-dm-verity-image` from the Red Hat registry, verifies its signature via cosign, and extracts pre-computed PCR values. These are the same values previously collected by `scripts/get-pcr.sh`.

### Bare Metal

```bash
# Collect firmware values from OCP release artifacts
make collect-firmware-refvals

# Or with explicit OCP version:
./scripts/collect-firmware-refvals.sh --ocp-version 4.20.18

# Specify TEE type (default: tdx):
./scripts/collect-firmware-refvals.sh --tee snp --ocp-version 4.20.18
```

Output: `~/.coco-pattern/firmware-reference-values.json`

Veritas resolves the kata-containers and edk2-ovmf RPMs from the OCP release payload (pinned by digest) and computes the expected firmware hashes.

### Script Options

```bash
./scripts/collect-firmware-refvals.sh --help

Options:
  --platform <platform>    Platform: baremetal (default) or azure
  -o, --output <path>      Override output path
  -p, --pull-secret <path> Pull secret file (default: ~/pull-secret.json)
  -v, --ocp-version <ver>  OCP version (baremetal; default: auto-detect)
  --osc-version <ver>      OSC operator version (azure; default: auto-detect)
  -t, --tee <tdx|snp>      TEE type (default: tdx)
```

## Loading Values to Vault

### Step 1: Configure values-secret.yaml

Azure reference values use the `pcrStash` secret (already enabled by default in `~/values-secret-coco-pattern.yaml`).

Bare metal reference values use the `firmwareReferenceValues` secret. Uncomment this section in `~/values-secret-coco-pattern.yaml`:

```yaml
- name: firmwareReferenceValues
  vaultPrefixes:
  - hub
  fields:
  - name: json
    path: ~/.coco-pattern/firmware-reference-values.json
```

### Step 2: Push to Vault

```bash
make load-secrets
```

### Step 3: Verify (optional)

```bash
# Check Vault
vault kv get secret/hub/firmwareReferenceValues  # bare metal
vault kv get secret/hub/pcrStash                 # azure

# Check RVPS ConfigMap on cluster
oc get configmap rvps-reference-values -n trustee-operator-system -o yaml
```

If updating an existing deployment, force the ExternalSecret to re-sync:

```bash
oc delete externalsecret firmware-refvals-eso -n trustee-operator-system  # bare metal
oc delete externalsecret pcrs-eso -n trustee-operator-system              # azure
```

## Multi-Version Support

Different OCP versions (bare metal) or OSC versions (Azure) may ship different artifacts. To support multiple versions, collect for each version and the values will be merged into arrays:

```bash
# Bare metal: run once per OCP version
./scripts/collect-firmware-refvals.sh --ocp-version 4.20.15 -o /tmp/fw-4.20.15.json
./scripts/collect-firmware-refvals.sh --ocp-version 4.20.18 -o /tmp/fw-4.20.18.json
# Manually merge with jq or re-run with all versions via veritas directly
```

The attestation policy uses `in` (set membership) — a workload passes if its measurement matches **any** value in the array.

## SHA-256 vs SHA-384

Different hash algorithms are used at different layers:

- **Azure vTPM PCRs**: SHA-256 (TPM 2.0 standard)
- **Bare metal TDX firmware**: SHA-384 (Intel TDX architecture)
- **Bare metal SNP firmware**: SHA-384 (AMD SEV-SNP architecture)
- **init_data TOML**: SHA-256 (CoCo initdata spec)

These are correct — the attestation policy checks them independently.

## Attestation Policy Coverage

The following table maps what veritas provides vs what the attestation policy checks:

| Check | Bare Metal TDX | Bare Metal SNP | Azure TDX | Azure SNP |
|-------|---------------|---------------|-----------|-----------|
| Firmware (OVMF) | mr_td | (part of launch measurement) | mr_td | (part of measurement) |
| Launch digest | - | snp_launch_measurement | - | measurement |
| Kernel+initrd | rtmr_1 | (part of launch measurement) | pcr09 | pcr09 |
| Kernel cmdline | rtmr_2 | (part of launch measurement) | pcr11 | pcr11 |
| CPU features | xfam | - | xfam | - |
| Debug disabled | Policy hardcoded | Policy hardcoded | - | - |
| TEE type | Policy hardcoded | - | Policy hardcoded | - |
| Init data | Computed by imperative job | Computed by imperative job | Computed by imperative job | Computed by imperative job |

## Known Limitations

As of the coco-tools 1.12 container:

1. **TCB version numbers** — Not collected for SNP (reported_tcb_bootloader, tcb_microcode, etc.). Hardware trust claim fallback rules handle this.
2. **SNP policy configuration** — SMT, TSME, guest ABI not output. Configuration fallback rules check debug disabled + init_data.
3. **rtmr_2 variants** — Veritas generates multiple cmdline variants (nr_cpus=1..N). If the actual cmdline differs, the policy falls back to the rtmr_1-only rule (executables: 4 instead of 3).

## Security Considerations

The attestation policy enforces `debug == false` for both TDX and SNP. Debug mode allows memory inspection via the hypervisor and must never be enabled for production workloads.

## References

- [Veritas](https://github.com/confidential-devhub/veritas) — reference value computation tool
- [Trustee Attestation Policy](https://github.com/openshift/trustee-operator/tree/main/config/templates) — upstream default policy
- [Intel TDX Spec](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-trust-domain-extensions.html)
- [AMD SEV-SNP Spec](https://www.amd.com/en/developer/sev.html)
