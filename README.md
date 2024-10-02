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
   1. This currently is a work in progress.
   



## Current constraints and assumptions
- Only currently is known to work with `azure` as the provider of confidential vms via peer-pods
- Only known to work today with everything on one cluster. The goal is to fix this as soon as possible. 
- You must be able to get a lets-encrypt certificate
- RHOAI data science cluster must be disabled until required components are deployed.
- Must be on 4.16.14 or later.


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



#### Configuring secrets / params
1. Setup `values-secret-coco-pattern.yaml` from the template
1. If you have not previously, run `./scripts/gen-ssh-key-azure.sh`
2. If you have not previously, run `./scripts/gen-kbs-keys.sh`
3. Populate the azure details between those that must be known already (CLIENT_ID etc) and using, when logged into `az`, `sh ./get-azure-details.sh`
4. Update `charts/all/sandbox/values.yaml` with the appropriate azure details
5. Recommended: Disable the kata config until system is up.

#### required `values-global.yaml` configuration

The following fields must be populated for 
```yaml
global:
  azure:
    clientID: ''
    subscriptionID: ''
    tenantID: ''
    DNSResGroup: ''
    hostedZoneName: ''
    clusterResGroup: ''
    clusterSubnet: ''
    clusterNSG: ''
    clusterRegion: ''
```


#### Install the pattern
1. `./pattern.sh make install` this *should* deploy all elements.
2. If it does not:
   1. Likely that the hello-openshift deployments timed out without the vm templates



## Future work
- Support spreading remote attestation and workload to separate clusters
- Finish AI work .
- Allow use of bare metal infrastructure with Intel TDX or AMD SEV-SMP



