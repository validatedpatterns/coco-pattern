# coco-pattern
This pattern deploys an mvp confidential computing pattern with OpenShift AI



## Current constraints and assumptions
- Currently is pre-release of `trustee` and `sandbox-containers v1.7.*` to the Red Hat operator hub
- Only currently is known to work with `azure` as the provider of confidential vms via peer-pods

## Using pre-release sandbox container operator
Pre-release sandbox container operator is accessible only via Red Hat / partners on an authenticated registry.
To use this you need to update the canonical pull secret (oc get secret/pull-secret -n openshift-config) with the extra registry.

### Procedural steps

1. `oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' |
base64 -d > authfile`

2. `podman login --authfile authfile --username "(username)" --password "(password)" brew.registry.redhat.io`

3. `oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=authfile`



## Future work
- Update to mainstream `trustee` and `sandbox container operator`
- Allow use of bare metal infrastructure with Intel TDX or AMD SEV-SMP


## Global flags
- 1. global.cocoUpstream = true - deploy trustee / sandbox containers from upstream`
- 2. global.cocoConverged = true - operate on a single cluster that will be insecure.
- 






## Reference

### Trustee
- https://github.com/lmilleri/trustee-operator-install/tree/main
- https://github.com/bpradipt/coco-install/tree/main/misc/kbs-operator-install


## OSC / coco stack
git clone https://github.com/bpradipt/coco-install
cd coco-install/osc-image-deploy
./install.sh

## High level pattern topology

- Hub cluster contains all privileged components (vault; kbs; AS etc)
- 




