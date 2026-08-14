# KubeVirt Confidential Containers (Experimental)

> **Status: EXPERIMENTAL** -- This chart is not production-ready. It targets hardware
> and KubeVirt APIs that are under active development. Expect breaking changes.

## Purpose

Deploys a HyperConverged CR patch enabling the TDX feature gate for confidential
virtual machines, plus a MachineConfig-based SELinux policy that grants QEMU access
to the QGS (Quote Generation Service) socket required for TDX attestation inside VMs.

## Hardware Requirements

- **CPU:** Intel processor with Trust Domain Extensions (TDX) support
- **BIOS:** SGX must be enabled in BIOS (TDX depends on SGX infrastructure for
  attestation collateral provisioning via the Intel DCAP stack)
- **Firmware:** Platform BIOS/firmware that exposes TDX capabilities to the OS

## KubeVirt Version Gap

The `confidentialCompute` API in the HyperConverged CR requires KubeVirt versions
**after v1.8.4**. As of this writing, v1.8.4 is the latest version shipped in
OpenShift Container Virtualization (CNV). The TDX feature gate behavior may change
in future KubeVirt releases -- pin your CNV subscription channel accordingly.

## Enablement

This chart renders empty when disabled (the default). To enable:

```yaml
# In your topology values file (e.g., values-baremetal.yaml)
kubevirtconfidential:
  overrides:
    - name: global.kubevirt.confidential.enabled
      value: "true"
```

Or set `global.kubevirt.confidential.enabled: "true"` via any values override mechanism.

## What Gets Deployed

When enabled, the chart creates:

1. **HyperConverged CR patch** -- enables the `WorkloadEncryptionSEV` feature gate
   (which also covers TDX on Intel platforms)
2. **SELinux MachineConfig** -- installs a custom SELinux policy module
   (`kubevirt-qgs`) allowing QEMU processes to connect to the QGS unix socket
3. **RHEL 9 ImageStream import job** -- imports the RHEL 9 guest image into the
   internal registry for VM boot via DataImportCron
