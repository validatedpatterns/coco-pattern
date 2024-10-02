# coco-pattern
This is a validated pattern for deploying confidential containers on OpenShift.

The target operating model has two clusters: 

- One in a "trusted" zone where the remote attestation, KMS and Key Broker infrastructure are deployed.
- A second where a subset of workloads are deployed in confidential containers 

**For the current version of this application the confidential containers assumes deployment to Azure**

On the platform a few workloads are deployed:
 
1. Sample hello world applications to allow users to experiment with the policies for CoCo and the KBS (trustee).
   1. This is currently working out of the box (or close to)

2. Red Hat OpenShift AI is deployed where a multi-layer perceptron to predict fraud is deployed as a confidential workload for inference
   1. This currently is a working
   



## Current constraints and assumptions
- Currently is pre-release of `trustee` and `sandbox-containers v1.7.*` to the Red Hat operator hub
- Only currently is known to work with `azure` as the provider of confidential vms via peer-pods
- You must be able to get a lets-encrypt certificate
- 

## Bootstrapping

#### Install of OCP cluster on azure.

**NOTE: Don't use the default node sizes.. increase the node sizes such as below**

1. Login to console.redhat.com
2. Get the openshift installer
3. Login to azure locally.
4. `openshift-install create install-config`
   1. Select azure
   2. For Red Hatter's and partners using RHDP make sure you select the same region for your account that you selected in RHDP
5. Change worker machine type e.g.
```yaml
  platform:
    azure:
      type: Standard_D8s_v5
```
1. `mkdir ./ocp-install && mv openshift-install.yaml ./ocp-install`
2. `openshift-install create cluster --dir=./ocp-install`



#### Configuring secrets / parms

1. If you have not previously, run `./scripts/gen-ssh-key-azure.sh`
2. If you have not previously, run `./scripts/gen-kbs-keys.sh`
3. Populate the azure details between those that must be known already (CLIENT_ID etc) and using, when logged into `az`, `sh ./get-azure-details.sh
4. Update `charts/all/sandbox/values.yaml` with the appropriate azure details
5. Recommended: Disable the kata config until system is up.


#### Install the pattern
`./pattern.sh make install`
After everything has come up.. deploy the kata config.



 

# Label nodes:
oc label node coco-kfrpp-worker-large-eastus1-k8fbn cluster.ocs.openshift.io/openshift-storage=""


## Issues 


## Future work
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




