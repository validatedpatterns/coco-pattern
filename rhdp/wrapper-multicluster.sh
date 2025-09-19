#!/usr/bin/env bash
set -e

# Function to detect available python binary
get_python_cmd() {
    if command -v python3 &> /dev/null; then
        echo "python3"
    elif command -v python &> /dev/null; then
        echo "python"
    else
        echo "ERROR: Neither python3 nor python is available" >&2
        exit 1
    fi
} 

if [ "$#" -ne 1 ]; then
    echo "Error: Exactly one argument is required."
    echo "Usage: $0 {azure-region-code}"
    echo "Example: $0 eastasia"
    exit 1
fi
AZUREREGION=$1

echo "---------------------"
echo "Validating configuration"
echo "---------------------"

# Check if values-global.yaml exists
if [ ! -f "values-global.yaml" ]; then
    echo "ERROR: values-global.yaml file not found in current directory"
    echo "Please run this script from the root directory of the project"
    exit 1
fi

# Check if yq is available
if ! command -v yq &> /dev/null; then
    echo "ERROR: yq is required but not installed"
    echo "Please install yq: https://github.com/mikefarah/yq#install"
    exit 1
fi

# Extract clusterGroupName from values-global.yaml using yq
CLUSTER_GROUP_NAME=$(yq eval '.main.clusterGroupName' values-global.yaml)

if [ "$CLUSTER_GROUP_NAME" != "trusted-hub" ]; then
    echo "ERROR: Incorrect clusterGroupName configuration"
    echo "Expected: trusted-hub"
    echo "Found: $CLUSTER_GROUP_NAME"
    echo ""
    echo "Please update values-global.yaml:"
    echo "  main:"
    echo "    clusterGroupName: trusted-hub"
    exit 1
fi

echo "Configuration validation passed: clusterGroupName = $CLUSTER_GROUP_NAME"

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
PYTHON_CMD=$(get_python_cmd)
$PYTHON_CMD rhdp/rhdp-cluster-define.py --multicluster ${AZUREREGION}
echo "---------------------"
echo "clusters defined"
echo "---------------------"
sleep 10

echo "---------------------"
echo "creating hub cluster first"
echo "---------------------"
openshift-install create cluster --dir=./openshift-install-hub --log-level=info
echo "hub cluster creation done"
echo "---------------------"

echo "setting up secrets"
bash ./scripts/gen-secrets.sh

echo "---------------------"
echo "starting pattern install on hub cluster"
echo "---------------------"
export KUBECONFIG="$(pwd)/openshift-install-hub/auth/kubeconfig"

# Start pattern installation in background
./pattern.sh make install &
PATTERN_PID=$!
echo "Pattern installation started in background (PID: $PATTERN_PID)"

echo "---------------------"
echo "creating spoke cluster (while pattern installs)"
echo "---------------------"
openshift-install create cluster --dir=./openshift-install-spoke --log-level=info &
SPOKE_PID=$!
echo "Spoke cluster creation started in background (PID: $SPOKE_PID)"

# Wait for pattern installation to complete
echo "Waiting for pattern installation to complete..."
wait $PATTERN_PID
PATTERN_EXIT_CODE=$?

if [ $PATTERN_EXIT_CODE -ne 0 ]; then
    echo "ERROR: Pattern installation failed with exit code $PATTERN_EXIT_CODE"
else
    echo "Pattern installation completed successfully!"
fi

# Wait for spoke cluster to complete
echo "Waiting for spoke cluster creation to complete..."
wait $SPOKE_PID
SPOKE_EXIT_CODE=$?

if [ $SPOKE_EXIT_CODE -ne 0 ]; then
    echo "WARNING: Spoke cluster creation failed with exit code $SPOKE_EXIT_CODE"
else
    echo "Spoke cluster creation completed successfully!"
fi

echo "---------------------"
echo "Deployment Summary"
echo "---------------------"
echo "Hub cluster (coco-hub) kubeconfig: $(pwd)/openshift-install-hub/auth/kubeconfig"

if [ $SPOKE_EXIT_CODE -eq 0 ]; then
    echo "Spoke cluster (coco-spoke) kubeconfig: $(pwd)/openshift-install-spoke/auth/kubeconfig"
    echo "Both clusters deployed successfully!"
else
    echo "Spoke cluster (coco-spoke): FAILED (exit code: $SPOKE_EXIT_CODE)"
    echo "Only hub cluster available"
fi

if [ $PATTERN_EXIT_CODE -eq 0 ]; then
    echo "Pattern: Successfully deployed to hub cluster"
else
    echo "Pattern: FAILED to deploy (exit code: $PATTERN_EXIT_CODE)"
fi

echo "---------------------"
echo "done"
echo "---------------------"