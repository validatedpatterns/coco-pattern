# coco-demo-pattern
This pattern deploys an mvp confidential computing pattern with OpenShift AI

## Current constraints and assumptions
- Currently is pre-release of `trustee` and `sandbox-containers v1.7.*` to the Red Hat operator hub
- Only currently is known to work with `azure` as the provider of confidential vms via peer-pods

## Future work
- Update to mainstream `trustee` and `sandbox container operator`
- Allow use of bare metal infrastructure with Intel TDX or AMD SEV-SMP


## Global flags
- 1. global.upstream = true - deploy trustee / sandbox containers from upstream`
- 2. global.converged = true - operate on a single cluster that will be insecure.
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




