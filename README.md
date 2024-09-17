# coco-pattern
This pattern deploys an mvp confidential computing pattern with OpenShift AI



## Current constraints and assumptions
- Currently is pre-release of `trustee` and `sandbox-containers v1.7.*` to the Red Hat operator hub
- Only currently is known to work with `azure` as the provider of confidential vms via peer-pods

## Using pre-release sandbox container operator
Pre-release sandbox container operator is accessible only via Red Hat / partners on an authenticated registry.
To use this you need to update the canonical pull secret (oc get secret/pull-secret -n openshift-config) with the extra registry.

### Procedural steps

#### Install of OCP cluster on azure.

**NOTE: Don't use the default node sizes. Parts of ODF are deployed and soak up a quite a bit of memory.**

1. Login to console.redhat.com
2. Get the openshift installer
3. Login to azure locally.
4. `openshift-install create install-config`
5. Change worker machine type e.g.
```yaml
  platform:
    azure:
      type: Standard_D16s_v5
      osImage:
        publisher: redhat
        offer: rh-ocp-worker
        sku: rh-ocp-worker
        version: 413.92.2023101700
```

#### Setting up cluster to use pre-prod tags. Do this before deploying the validated pattern.
1. `oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' |
base64 -d > authfile`

2. `podman login --authfile authfile --username "(username)" --password "(password)" brew.registry.redhat.io`

3. `oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=authfile`

#### Configuring secrets / parms

1. If you have not previously, run `./scripts/gen-ssh-key-azure.sh`
2. If you have not previously, run `./scripts/gen-kbs-keys.sh`
3. Populate the azure details between those that must be known already (CLIENT_ID etc) and using, when logged into `az`, `sh ./get-azure-details.sh
4. Update `charts/all/sandbox/values.yaml` with the appropriate azure details
5. Recommended: Disable the kata config until system is up.


#### Install the pattern
`./pattern.sh make install`
After everything has come up.. deploy the kata config.







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




