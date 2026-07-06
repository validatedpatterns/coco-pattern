# hello-openshift

Three deployments demonstrating confidential containers on Red Hat httpd-24, each with a different security posture.

All three use `registry.redhat.io/ubi9/httpd-24` on port 8080 with custom web content served from ConfigMaps.

## Deployments

### standard

Non-confidential baseline. Runs without `kata-cc` runtime — standard OCI container for comparison.

| Field | Value |
|-------|-------|
| Route | `http://standard-hello-openshift.apps.<cluster>/` |
| Runtime | default (runc) |
| Initdata | none |
| Web content | `standard-web-content` ConfigMap |

### insecure-policy

Confidential container using `kata-cc` runtime with the `debug-initdata` ConfigMap (insecure/debug attestation policy). Useful for development and troubleshooting — allows `oc exec` and relaxed attestation.

| Field | Value |
|-------|-------|
| Route | `http://insecure-policy-hello-openshift.apps.<cluster>/` |
| Runtime | `kata-cc` |
| Initdata | `debug-initdata` (insecure policy) |
| Web content | `insecure-policy-web-content` ConfigMap |

### secure

Confidential container using `kata-cc` runtime with the production `initdata` ConfigMap (signed/verified attestation policy). Blocks `oc exec` and enforces attestation.

| Field | Value |
|-------|-------|
| Route | `http://secure-hello-openshift.apps.<cluster>/` |
| Runtime | `kata-cc` |
| Initdata | `initdata` (production policy) |
| Web content | `secure-web-content` ConfigMap |
