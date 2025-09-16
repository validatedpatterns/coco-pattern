#!/usr/bin/env bash
set -e 

if [ "$#" -ne 1 ]; then
    echo "Error: Exactly one argument is required."
    echo "Usage: $0 {azure-region-code}"
    echo "Example: $0 eastasia"
    exit 1
fi
AZUREREGION=$1

echo "Run from the root directory of the project"
echo "This will deploy two clusters: coco-hub and coco-spoke in the same region"
echo ""
echo "Ensuring azure environment is installed"

if [ ! -n "${GUID}" ]; then
   echo "RHDP GUID environmental variable does not exist"
   exit 1
fi
if [ ! -n "${CLIENT_ID}" ]; then
   echo "RHDP AZURE 'CLIENT_ID' environmental variable does not exist"
   exit 1
fi
if [ ! -n "${PASSWORD}" ]; then
   echo "RHDP AZURE 'PASSWORD' environmental variable aka client secret does not exist"
   exit 1
fi
if [ ! -n "${TENANT}" ]; then
   echo "RHDP AZURE 'TENANT' environmental variable does not exist"
   exit 1
fi
if [ ! -n "${SUBSCRIPTION}" ]; then
   echo "RHDP AZURE 'SUBSCRIPTION' environmental variable does not exist"
   exit 1
fi
if [ ! -n "${RESOURCEGROUP}" ]; then
   echo "RHDP AZURE 'RESOURCEGROUP' environmental variable does not exist"
   exit 1
fi

sleep 10
echo "---------------------"
echo "Installing python dependencies"
echo "---------------------"
pip install -r rhdp/requirements.txt
echo "---------------------"
echo "requirements installed"
echo "---------------------"
sleep 5

if [ ! -f "${HOME}/pull-secret.json" ]; then
   echo "A OpenShift pull secret is required at ~/pull-secret.json"
   exit 1
fi

if [ ! -f "${HOME}/.ssh/id_rsa" ]; then
   echo "An rsa ssh key is required at ~/.ssh/id_rsa"
   echo "e.g. ssh-keygen -t rsa -b 4096"
   echo "TBC: Update to support other key types"
   exit 1
fi

echo "---------------------"
echo "defining both clusters (hub and spoke)"
echo "---------------------"
python rhdp/rhdp-cluster-define.py --multicluster ${AZUREREGION}
echo "---------------------"
echo "clusters defined"
echo "---------------------"
sleep 10

echo "---------------------"
echo "creating hub cluster (coco-hub)"
echo "---------------------"
openshift-install create cluster --dir=./openshift-install-hub --log-level=info
echo "hub cluster creation done"
echo "---------------------"

echo "---------------------"
echo "creating spoke cluster (coco-spoke)"
echo "---------------------"
openshift-install create cluster --dir=./openshift-install-spoke --log-level=info
echo "spoke cluster creation done"
echo "---------------------"

echo "setting up secrets"
bash ./scripts/gen-secrets.sh

sleep 60
echo "---------------------"
echo "pattern install on hub cluster"
echo "---------------------"
export KUBECONFIG=`pwd`/openshift-install-hub/auth/kubeconfig

./pattern.sh make install
echo "---------------------"
echo "pattern install done on hub cluster"
echo "---------------------"

echo "---------------------"
echo "Deployment Summary"
echo "---------------------"
echo "Hub cluster (coco-hub) kubeconfig: $(pwd)/openshift-install-hub/auth/kubeconfig"
echo "Spoke cluster (coco-spoke) kubeconfig: $(pwd)/openshift-install-spoke/auth/kubeconfig"
echo "Pattern deployed to hub cluster only"
echo "---------------------"
