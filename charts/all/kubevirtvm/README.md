# KubeVirt Virtual Machines (Experimental)

> **Status: EXPERIMENTAL** -- This chart is not production-ready. It deploys test
> virtual machines for validating KubeVirt and TDX confidential VM functionality.
> Expect breaking changes as the KubeVirt confidentialCompute API evolves.

## Purpose

Deploys baseline RHEL 9 virtual machines and optionally TDX-protected confidential
VMs for testing KubeVirt integration with the CoCo pattern. These VMs validate that
KubeVirt is functional and that TDX launch security works end-to-end with the
attestation stack.

## Prerequisites

- **KubeVirt HCO:** The `kubevirt-hyperconverged` subscription must be deployed and
  healthy (the `cnv` subscription in your topology values file)
- **For TDX VMs:** The `kubevirtconfidential` chart must be enabled first (deploys
  the HyperConverged CR patch with the TDX feature gate)
- **Storage:** A default StorageClass must be available (LVM or other) for VM disk
  provisioning via DataVolumes

## Enablement

This chart renders empty when disabled (the default). To enable:

```yaml
# In your topology values file (e.g., values-baremetal.yaml)
kubevirtvm:
  overrides:
    - name: global.kubevirt.vm.enabled
      value: "true"
    # Optional: enable TDX launch security on VMs
    - name: global.kubevirt.vm.tdx.enabled
      value: "true"
```

## What Gets Deployed

When enabled with `global.kubevirt.vm.enabled: "true"`:

1. **Baseline RHEL 9 VM** -- a standard (non-confidential) virtual machine that
   validates KubeVirt is working correctly before adding TDX launch security

When additionally enabled with `global.kubevirt.vm.tdx.enabled: "true"`:

2. **TDX Confidential VM** -- a RHEL 9 VM with TDX launch security enabled,
   validating end-to-end confidential compute inside KubeVirt
