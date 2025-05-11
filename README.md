# coco-pattern
This is a validated pattern for deploying confidential containers on OpenShift.

The target operating model has two clusters: 

- One in a "trusted" zone where the remote attestation, KMS and Key Broker infrastructure are deployed.
- A second where a subset of workloads are deployed in confidential containers 

**For the current version of this application the confidential containers assumes deployment to Azure**

On the platform a a sample workload is deployed
 
1. Sample hello world applications to allow users to experiment with the policies for CoCo and the KBS (trustee).
2. A sample application `kbs-access` which presents secrets obtained from trustee to a web service. This is designed to allow users to test locked down environments.

Future work includes:

1. Supporting a multiple cluster deployment
2. Supporting multiple infrastructure providers
3. Supporting a more sophisticated workload such as confidential AI inference with protected GPUs.


## Current constraints and assumptions

- Only currently is known to work with `azure` as the provider of confidential vms via peer-pods.
- Only known to work today with everything on one cluster. The work to expand this is in flight.
- If not using ARO you must either provide your own CA signed certs, or use let's encrypt.
- Must be on 4.16.14 or later.

> [!IMPORTANT]
> Users must provide a NAT Gateway attached to the worker node subnet when using Azure.

## Major versions

### `2.*`
This is currently the `main` branch for the repository. Version 2.* of the pattern is currently constrained to support:
- (OpenShift Sandboxed Containers Operator) `1.9.*`
- Trustee `0.3.*`

This limits support to OpenShift 4.16 and higher.

The pattern has been tested on Azure for two installation methods:
1. Installing onto an ARO cluster
2. Self managed OpenShift install using the `openshift-install` CLI.

> [!IMPORTANT]
> You need an external CA signed certificate for to be added (e.g. with let's encrypt) to a self-managed install

### `1.0.0`
1.0.0 supports OpenShift Sandboxed containers version `1.8.1` along with Trustee version `0.2.0`.

The pattern has been tested on Azure for one installation method:
1. Self managed OpenShift install using the `openshift-install` CLI



## validated pattern flavours 
**Today the demo has one flavour**. 
A number are planned based on various different hub cluster-groups.
You can change between behaviour by configuring [`global.main.clusterGroupName`](https://validatedpatterns.io/learn/values-files/) key in the `values-global.yaml` file. 


`values-simple.yaml`: or the `simple` cluster group is the default for the pattern.
It deploys a hello-openshift application 3 times: 
- A standard pod
- A kata container with peer-pods
- A confidential kata-container

## Setup instructions


### Default single cluster setup with `values-simple.yaml`

The instructions here presume you have a cluster. See further down for provisioning instructions for a cluster.

#### Fork and Clone the GitHub repo
1. Following [standard validated patterns workflow](https://validatedpatterns.io/learn/workflow/) fork the repository and clone to your development environment which has `podman` and `git`
2. If using a particular version (e.g. `1.0.0`) checkout the correct tag.

> [!TIP]
> Forking is essential as the validated pattern uses ArgoCD to reconcile it's state against your remote (forked) repository. 


#### Configuring required secrets / parameters
The secrets here secure Trustee and the peer-pod vms. Mostly they are for demonstration purposes. 
This only has to be done once.

1. Run `sh scripts/gen-secrets.sh`

> [!NOTE]
> Once generated this script will not override secrets. Be careful when doing multiple tests.

#### Check your cluster on Azure has a NAT gateway attached
OpenShift does not require a NAT gateway by default, however, peer-pods do require a NAT gateway attached to the worker node subnet.

> [!NOTE]
> 
#### Configuring let's encrypt.

> [!IMPORTANT]
> Ensure you have password login available to the cluster. Let's encrypt will replace the API certificate in addition to the certificates to user with routes.


Trustee requires a trusted CA issued certificate. Let's Encrypt is included for environments without a trusted cert on OpenShift's routes.

If you need a Let's Encrypt certificate to be issued the `letsencrypt` application configuration needs to be changed as below.
```yaml
    
    ---
    # Default configuration, safe for ARO
    letsencrypt:
      name: letsencrypt
      namespace: letsencrypt
      project: hub
      path: charts/all/letsencrypt
      # Default to 'safe' for ARO
      overrides:
      - name: letsencrypt.enabled
        value: false
    ---
    # Explicitly correct configuration for enabling let's encrypt
    letsencrypt:
      name: letsencrypt
      namespace: letsencrypt
      project: hub
      path: charts/all/letsencrypt
      overrides:
      - name: letsencrypt.enabled
        value: true  
```

> [!WARNING]
> Configuration changes are only effective once committed and pushed to your remote repository.

#### Installing onto a cluster
Once you configuration is pushed (if required) `./pattern.sh make install` to provision a cluster. 

> [!TIP]
> The branch and default origin you have checked-out in your local repository is used to determine what ArgoCD and the patterns operator should reconcile against. Typical choices are to use the main for your fork.

## Cluster setup (if not already setup)

### Single cluster install on an OCP cluster on azure using Red Hat Demo Platform

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
1. Ensure Let's encrypt 
1. Run the wrapper install script 
  1. `bash ./rhdp/wrapper.sh azure-region-code`
  2. Where azure region code is `eastasia`, `useast2` etc.
1. You *should* be done
  1. You *may* need to recreate the hello world peer-pods depending on timeouts.

### Single cluster install on plain old azure *not* using Red Hat Demo Platform
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
  2. Configure Let's Encrypt (if required)
  3. `./pattern.sh make install`

### Multi cluster setup
TBD
