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

Both platforms use the [veritas](https://github.com/confidential-devhub/veritas) tool. No cluster access is required — veritas computes expected measurements from OCP release artifacts or the dm-verity image.

By default, `collect_firmware_refvals.py` collects reference values for **both TDX and SNP and merges them** into a single output, so one RVPS ConfigMap supports heterogeneous (mixed-TEE) deployments out of the box — see [Multi-Architecture Collection](#multi-architecture-collection) below.

## Prerequisites

- Python 3.10+ with the shared script dependencies: `python3 -m pip install -r requirements.txt` (includes `veritas`, Typer, Rich, and PyYAML)
- `cosign` >= 2.0 — Azure only, used by veritas to verify the Red Hat dm-verity image signature: <https://docs.sigstore.dev/cosign/system_config/installation/>
- OpenShift pull secret at `~/pull-secret.json` (override the location with the `PULL_SECRET` environment variable or `--pull-secret`)
- For bare metal: OCP version of your cluster (auto-detected if `oc` is logged in, set `OCP_VERSION`, or pass `--ocp-version` explicitly)
- For bare metal TDX: `tdx-measure` (`cargo install --git https://github.com/virtee/tdx-measure tdx-measure-cli`) — collection continues with a warning if absent, but TDX RTMR values will be incomplete

**Why host-installed instead of the `coco-tools` container**: the container image (`quay.io/openshift_sandboxed_containers/coco-tools:0.5.1`) is pinned to an older veritas release that lacks `--skip-tlog`, which is needed to avoid the Azure verification failures described below. This is a deliberate, temporary deviation — see the tracking issue referenced in [Known Limitations](#known-limitations) for moving back to the container once a `coco-tools` release ships with a newer veritas.

## OSC Version Resolution

Both the Azure image tag and the Trustee wire format (`--bot-version`; see
below) depend on the OSC operator version. `collect_firmware_refvals.py`
resolves it as follows, for **both** platforms:

1. `--osc-version` (repeatable) if given — always wins.
2. Otherwise, `clusterGroup.subscriptions.sandbox.csv` is read from
   `--values-file` (default: `values-azure.yaml` / `values-baremetal.yaml`,
   matching `--platform`) and the version is extracted from the pinned CSV
   (e.g. `sandboxed-containers-operator.v1.13.0` → `1.13.0`).
3. If neither resolves a version, the script **exits with an error** asking
   for an explicit `--osc-version`.

There is deliberately no live-cluster auto-detection and no silent
`"latest"` fallback for OSC version. Reference values must match what the
pattern's own values files declare — not whatever happens to be installed
on whichever cluster you ran the collector against. (An earlier version of
this script did auto-detect from a live cluster and fall back to `"latest"`
if that failed, which silently collected the wrong PCR values whenever the
installed/live OSC version didn't match the pattern's pinned version — see
the Git history of this file for the incident this fixed.)

The resolved OSC version also determines veritas's `--bot-version` (Red Hat
build of the Trustee RVPS wire format: `"1.2"` for OSC >= 1.13, `"1.1"` for
OSC <= 1.12). This is a structural format switch (flat JSON array vs a
base64-encoded map), not just a version stamp, and is now always passed to
veritas explicitly.

OCP version (bare metal only) is unaffected by this — there is no
values-file pin for the exact OCP patch. It resolves in this order:

1. `--ocp-version` (repeatable), if supplied.
2. `OCP_VERSION`, if set.
3. Live-cluster auto-detection through an authenticated `oc` session.

Use `OCP_VERSION` when reference values are collected before a cluster is
available, such as from a connected staging host preparing artifacts for a
fully air-gapped environment. The variable accepts one OCP version; use the
repeatable `--ocp-version` option when collecting for multiple versions.

## Collecting Reference Values

### Azure

```bash
# Collect PCR values from the dm-verity image (OSC version read from
# values-azure.yaml's pinned subscription CSV)
make collect-azure-refvals

# Or with an explicit OSC version override:
./scripts/collect_firmware_refvals.py --platform azure --osc-version 1.13.1
```

Output: `~/.coco-pattern/measurements.json`

Veritas pulls the `osc-dm-verity-image` from the Red Hat registry, verifies its signature via cosign, and extracts pre-computed PCR values.

**Signature verification and Rekor**: by default this script passes `--skip-tlog` to veritas for the Azure branch. Red Hat signs and logs these images against its own private Rekor instance, which has been unreliable (repeated `curl` failures fetching the Rekor public key). `--skip-tlog` still verifies the cosign signature against Red Hat's public key — it only skips the transparency-log lookup, which cannot succeed against a different Rekor server anyway (the log entry only exists on Red Hat's instance, so pointing at a different one, e.g. public Sigstore, does not work as a substitute). Pass `--verify-tlog` to opt back into full transparency-log verification if needed.

### Bare Metal

```bash
# Collect firmware values from OCP release artifacts
make collect-firmware-refvals

# Collect without an authenticated cluster connection (for example, from a
# connected staging host preparing artifacts for a fully disconnected environment)
OCP_VERSION=4.22.8 make collect-firmware-refvals

# Or with explicit OCP version:
./scripts/collect_firmware_refvals.py --platform baremetal --ocp-version 4.20.18

# Collect a single TEE only (default is both, see below):
./scripts/collect_firmware_refvals.py --platform baremetal --tee snp --ocp-version 4.20.18
```

Output: `~/.coco-pattern/firmware-reference-values.json`

Veritas resolves the kata-containers and edk2-ovmf RPMs from the OCP release payload (pinned by digest) and computes the expected firmware hashes.

### Script Options

```bash
./scripts/collect_firmware_refvals.py --help

Options:
  --platform <platform>     Platform: baremetal or azure (required)
  -o, --output <path>       Override output path
  -p, --pull-secret <path>  Pull secret file (default: ~/pull-secret.json,
                            override via PULL_SECRET env var)
  -v, --ocp-version <ver>   OCP version (bare metal; repeatable; takes
                             precedence over OCP_VERSION and auto-detection)
  --osc-version <ver>       OSC operator version (repeatable; default: read
                            from --values-file's pinned subscription CSV)
  --values-file <path>      Values file to read the pinned OSC version from
                            (default: values-azure.yaml / values-baremetal.yaml,
                            matching --platform)
  -t, --tee <tdx|snp|both>  TEE type (default: both -- collects and merges both)
  --verify-tlog             Azure only: verify against Rekor instead of --skip-tlog
```

## Multi-Architecture Collection

By default (`--tee both`, or by omitting `--tee` entirely), this script runs veritas **twice** — once per TEE — and merges the resulting reference values into a single output file, for both the Azure and bare-metal branches. This supports heterogeneous/mixed-TEE deployments (for example, a bare-metal hub that verifies evidence from both TDX and SNP spokes, per `values-baremetal-hub.yaml`'s `kbs.tdx.enabled` + `kbs.snp.enabled`) without any manual merge step.

The merge is a plain JSON key union: TDX and SNP reference values use disjoint, TEE-prefixed key names (`tdx_*`/`mr_td`/`rtmr_*` vs `snp_*`/`snp_launch_measurement`), so there's no collision risk, and this matches how `trustee-chart`'s RVPS template already consumes the `firmwareReferenceValues`/`pcrStash` secrets (it passes through whichever TEE-specific keys are present).

Pass `--tee tdx` or `--tee snp` explicitly to collect a single architecture only (faster, useful for single-cluster deployments pinned to one hardware profile).

## Loading Values to Vault

### Step 1: Configure values-secret.yaml

Azure reference values use the `pcrStash` secret and bare metal reference
values use the `firmwareReferenceValues` secret. Both are enabled by default
in `~/values-secret-coco-pattern.yaml`, so the same file works unmodified on
either topology — nothing needs to be uncommented.

`collect_firmware_refvals.py` automatically creates an empty `{}` placeholder
for whichever of `~/.coco-pattern/measurements.json` /
`~/.coco-pattern/firmware-reference-values.json` you are *not* collecting, so
`make load-secrets` never fails with a missing-file error regardless of
platform. Real collected data always overwrites the placeholder for the
platform you actually run.

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

Different OCP versions (bare metal) or OSC versions (Azure) may ship different artifacts. Both `--ocp-version` and `--osc-version` are repeatable — pass each version you need to support and the resulting reference values are merged into arrays automatically in a single run (veritas itself merges across versions; this script merges across the `--tee` runs on top of that):

```bash
# Bare metal: collect for two OCP versions in one run
./scripts/collect_firmware_refvals.py --platform baremetal \
  --ocp-version 4.20.15 --ocp-version 4.20.18

# Azure: collect for two OSC versions in one run (e.g. during an upgrade window)
./scripts/collect_firmware_refvals.py --platform azure \
  --osc-version 1.13.0 --osc-version 1.13.1
```

If the given `--osc-version`s straddle the 1.13 `--bot-version` boundary (see [OSC Version Resolution](#osc-version-resolution)), the script warns and uses the newer (`1.2`) format.

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

## Azure "External" Reference Values (kbs.azure.*)

Azure SEV-SNP also has a second, separate set of reference values that veritas does **not** collect: `trustee-chart`'s `kbs.azure.*` block (`snpLaunchMeasurement`, `smtEnabled`, `tsmeEnabled`, `abiMajor`, `abiMinor`, `singleSocket`, `smtAllowed`). These are static Azure-platform/VM-series constants (describing the SEV-SNP policy Azure enforces for a given confidential VM series), not measurements derived from any artifact veritas can pull and hash.

coco-pattern pins these explicitly in `overrides/values-trustee-azure.yaml` (wired into `values-azure.yaml`) rather than silently relying on `trustee-chart`'s own defaults, so the values are visible/versioned in this repository. See that file's comments for the current VM-series mapping and for how to update them if you change `global.azure.defaultVMFlavour` to a series with different platform behavior.

**Note**: as of the current `trustee-chart` attestation policy, the Rego checks that would compare evidence against these values are commented out upstream ("Azure manages TCB validation"), so they are not currently enforced — they're pinned here so they're ready to take effect if/when upstream re-enables those checks, and so the values are documented and auditable rather than hidden inside a dependency chart's defaults.

There is currently no automated way to collect/verify these values against a real deployment. A `snpguest`-based collection script (SSH into the podvm with `enableSSHDebug`, run `snpguest report --openhcl`, parse the SNP attestation report) is tracked as a follow-up.

## Known Limitations

1. **TCB version numbers** — Not collected for SNP (reported_tcb_bootloader, tcb_microcode, etc.). Hardware trust claim fallback rules handle this.
2. **Azure SNP platform configuration** — SMT, TSME, guest ABI are not collected by veritas at all (see [Azure "External" Reference Values](#azure-external-reference-values-kbsazure) above); bare-metal SNP configuration fallback rules check debug disabled + init_data instead.
3. **rtmr_2 variants** — Veritas generates multiple cmdline variants (nr_cpus=1..N). If the actual cmdline differs, the policy falls back to the rtmr_1-only rule (executables: 4 instead of 3).
4. **Host-installed veritas instead of the `coco-tools` container** — temporary, until `coco-tools` publishes a release pinning a newer veritas with `--skip-tlog`/`--cosign-pub-key`/`--mirror-registry` support. See the tracking issue for details and for moving back to the container-based approach.

## Security Considerations

The attestation policy enforces `debug == false` for both TDX and SNP. Debug mode allows memory inspection via the hypervisor and must never be enabled for production workloads.

## References

- [Veritas](https://github.com/confidential-devhub/veritas) — reference value computation tool
- [Trustee Attestation Policy](https://github.com/openshift/trustee-operator/tree/main/config/templates) — upstream default policy
- [Intel TDX Spec](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-trust-domain-extensions.html)
- [AMD SEV-SNP Spec](https://www.amd.com/en/developer/sev.html)
