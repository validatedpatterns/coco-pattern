# Bug Report: NFD `matchAll` Field Silently Dropped, Causing False TEE Labels

## Summary

`matchAll` is not a valid field in the NFD `NodeFeatureRule.spec.rules[]` schema. The correct field for AND-logic matching is `matchFeatures` (top-level on each rule). When `matchAll` is used, the OpenShift NFD operator silently drops it during the `nfd.openshift.io/v1alpha1` to `nfd.k8s-sigs.io/v1alpha1` conversion, leaving rules with no match predicates. These empty rules match every node unconditionally, applying all TEE labels regardless of hardware.

## Impact

- Every node receives ALL TEE labels: `intel.feature.node.kubernetes.io/tdx`, `amd.feature.node.kubernetes.io/snp`, `ibm.feature.node.kubernetes.io/se`, and `intel.feature.node.kubernetes.io/sgx`
- The OpenShift sandboxed containers operator fails with: **`"multiple TEE platforms detected; only one per cluster supported"`**
- KataConfig cannot reconcile, so no kata runtime handler is installed
- All confidential container pods fail with: `failed to find runtime handler kata-snp from runtime list`

## Root Cause

The NFD `Rule` schema supports two match fields:

| Field | Behavior | Valid? |
|-------|----------|--------|
| `matchFeatures` | Top-level list of feature matchers; ALL must match (AND) | Yes |
| `matchAny` | List of match groups; ANY must match (OR) | Yes |
| `matchAll` | **Does not exist in the NFD API** | No |

When the chart template uses `matchAll`:

```yaml
# BROKEN - matchAll is not a valid field
- name: "amd.sev-snp"
  labels:
    amd.feature.node.kubernetes.io/snp: "true"
  matchAll:
    - matchFeatures:
        - feature: cpu.security
          matchExpressions:
            sev.snp.enabled: { op: Exists }
```

The OpenShift NFD operator creates a shadow resource under `nfd.k8s-sigs.io/v1alpha1`. During this conversion, `matchAll` is an unrecognized field and is silently stripped. The resulting live resource has:

```yaml
# RESULT - no match conditions, matches every node
- name: "amd.sev-snp"
  labels:
    amd.feature.node.kubernetes.io/snp: "true"
  labelsTemplate: ""
  varsTemplate: ""
```

## Evidence

**Node:** `master-03` (Intel Xeon, model family 6, ID 207, vendor: Intel)

**NFD-reported hardware features (`cpu.security`):**

```bash
sgx.enabled: "true"
sgx.epc: "4257210368"
```

Note: `sev.snp.enabled`, `tdx.enabled`, and `se.enabled` are **not present** in the node's feature data.

**Labels applied to the node (all false positives except sgx):**

```bash
amd.feature.node.kubernetes.io/snp=true    # FALSE - Intel CPU, no SEV-SNP
intel.feature.node.kubernetes.io/tdx=true  # FALSE - no tdx.enabled in cpu.security
ibm.feature.node.kubernetes.io/se=true     # FALSE - Intel CPU, no SE
intel.feature.node.kubernetes.io/sgx=true  # CORRECT - sgx.enabled is true
feature.node.kubernetes.io/runtime.kata=true  # CORRECT - matchAny works (valid field)
```

**Sandbox operator log:**

```text
INFO  controllers.KataConfig  failed to detect TEE platform
      {"err": "multiple TEE platforms detected; only one per cluster supported"}
```

## Fix

Replace `matchAll` with `matchFeatures` in each rule. The `matchFeatures` list at the rule level uses AND logic (all entries must match), which is the intended behavior.

Additionally, add vendor-discriminating CPUID checks to prevent cross-platform false positives:

```yaml
# FIXED - uses matchFeatures (valid field) with vendor guard
- name: "amd.sev-snp"
  labels:
    amd.feature.node.kubernetes.io/snp: "true"
  matchFeatures:
    - feature: cpu.cpuid
      matchExpressions:
        SVM: { op: Exists }           # AMD-only CPUID flag
    - feature: cpu.security
      matchExpressions:
        sev.snp.enabled: { op: Exists }
```

| Rule | `matchAll` (broken) | `matchFeatures` (fixed) | Vendor guard added |
|------|---------------------|-------------------------|--------------------|
| `amd.sev-snp` | Dropped silently | AND: SVM + sev.snp.enabled | `SVM` (AMD) |
| `intel.sgx` | Dropped silently | AND: SGX + SGXLC + sgx.enabled + X86_SGX | `SGX`, `SGXLC` (Intel) |
| `intel.tdx` | Dropped silently | AND: VMX + tdx.enabled | `VMX` (Intel) |
| `ibm.se.enabled` | Dropped silently | AND: se.enabled | None (s390x only) |

## Affected Versions

Any deployment using the consolidated `NodeFeatureRule` (`consolidated-hardware-features`) introduced in commit `57ec5f4`. The original separate NFD rule files (`amd-nfd-rules.yaml`, `intel-nfd-rules.yaml`) used `matchFeatures` correctly but the consolidation mistakenly introduced `matchAll`.

## Remediation

After deploying the corrected chart:

```bash
# Remove false labels so NFD can re-evaluate
oc label node <node> amd.feature.node.kubernetes.io/snp- \
  intel.feature.node.kubernetes.io/tdx- \
  ibm.feature.node.kubernetes.io/se-

# Restart sandbox operator to re-evaluate KataConfig
oc delete pod -n openshift-sandboxed-containers-operator -l app=controller-manager
```
