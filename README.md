# coco-pattern
This is a validated pattern for deploying confidential containers on OpenShift.

The target operating model has two clusters: 

- One in a "trusted" zone where the remote attestation, KMS and Key Broker infrastructure are deployed.
- A second where a subset of workloads are deployed in confidential containers 

**For the current version of this application the confidential containers assumes deployment to Azure**

On the platform a a sample workload is deployed
 
1. Sample hello world applications to allow users to experiment with the policies for CoCo and the KBS (trustee).
   1. This is currently working out of the box (or close to).

Future work includes:

2. Red Hat OpenShift AI is deployed where a multi-layer perceptron to predict fraud is deployed as a confidential workload for inference
2. Enirnonments which will work sucessfully across multiple cloud providers


## Current constraints and assumptions
- Only currently is known to work with `azure` as the provider of confidential vms via peer-pods
- Only known to work today with everything on one cluster. The work to expand this is in flight
- You must be able to get a lets-encrypt certificate. This means the service credentials in openshift must be able to manipulate the dns zone used by OpenSift.
- 
- RHOAI data science cluster must be disabled until required components are deployed.
- Must be on 4.16.14 or later.


## validated pattern flavours 
**Today the demo has one flavour**. 
A number are planned based on various different hub cluster-groups.
You can change between behaviour by configuring [`global.main.clusterGroupName`](https://validatedpatterns.io/learn/values-files/) key in the `values-global.yaml` file. 



`values-simple.yaml`: or the `simple` cluster group is the default for the pattern.
It deploys a hello-openshift application 3 times: 
- A standard pod
- A kata container with peer-pods
- A confidential kata-container

`values-ai.yaml`: Is currently a work in progress. 



## Setup instructions

### Default single cluster setup with `values-simple.yaml`

#### Configuring required secrets / parameters
The secrets here secure Trustee and the peer-pod vms. Mostly they are for demonstration purposes. 
This only has to be done once.

1. Run `sh scripts/gen-secrets.sh`

#### Install on an OCP cluster on azure using Red Hat Demo Platform

Red Hat a demo platform. This allows easy access for Red Hat associates and partners to ephemeral cloud resources. The pattern is known to work with this setup.
1. Get the [openshift installer](https://console.redhat.com/openshift/downloads)
   1. **NOTE: openshift installer must be updated regularly if you want to automatically provision the latest versions of OCP**
2. Get access to an [Azure Subscription Based Blank Open Environment](https://catalog.demo.redhat.com/catalog?category=Open_Environments&search=azure&item=babylon-catalog-prod%2Fazure-gpte.open-environment-azure-subscription.prod).
3. Import the required azure environmental variables (see coded block):
   ```
      export CLIENT_ID=
      export PASSWORD=
      export TENANT=
      export SUBSCRIPTION=
      export RESOURCEGROUP=
  ```
1. Run the wrapper install script 
  1. `sh ./rhdp/wrapper.sh`
1. You *should* be done
  1. You *may* need to recreate the hello world peer-pods depending on timeouts.

#### Install azure *not* usign Red Hat Demo platform
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
3. Once installed:
  1. Login to `oc`
  2. `./pattern.sh make install 


### Multi cluster setup
TBD

### Multi-cluster setup with AI
TBD

## Future work
- Support spreading remote attestation and workload to separate clusters.
- Finish AI work.
- Allow use of bare metal infrastructure with Intel TDX or AMD SEV-SMP.



