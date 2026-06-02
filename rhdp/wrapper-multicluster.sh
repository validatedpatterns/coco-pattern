#!/usr/bin/env bash
set -e

# Function to detect available python binary
get_python_cmd() {
    if command -v python &> /dev/null; then
        echo "python"
    elif command -v python3 &> /dev/null; then
        echo "python3"
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

# Check if podman is available and running
if ! command -v podman &> /dev/null; then
    echo "ERROR: podman is required but not installed"
    echo "Please install podman: https://podman.io/getting-started/installation"
    exit 1
fi

# Verify podman is running properly
if ! podman info &> /dev/null; then
    echo "ERROR: podman is installed but not responding"
    echo "Please ensure the podman service is running"
    echo "Try: podman machine start (for macOS/Windows) or check podman service status (for Linux)"
    exit 1
fi

echo "✓ podman is available and running"

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
echo "retrieving PCR measurements"
echo "---------------------"
bash ./scripts/collect-firmware-refvals.sh --platform azure

echo "---------------------"
echo "starting pattern install on hub cluster"
echo "---------------------"
export KUBECONFIG="$(pwd)/openshift-install-hub/auth/kubeconfig"

# Start pattern installation and capture exit code
set +e
./pattern.sh make install
PATTERN_EXIT_CODE=$?
set -e

echo "---------------------"
echo "creating spoke cluster (while pattern installs)"
echo "---------------------"
set +e
openshift-install create cluster --dir=./openshift-install-spoke --log-level=info
SPOKE_EXIT_CODE=$?
set -e


echo "---------------------"
echo "Verifying ACM deployment on hub cluster"
echo "---------------------"

# Ensure we're using the hub cluster kubeconfig
export KUBECONFIG="$(pwd)/openshift-install-hub/auth/kubeconfig"

# Check if ACM namespace exists
if ! kubectl get namespace open-cluster-management &> /dev/null; then
    echo "WARNING: ACM namespace 'open-cluster-management' not found"
    ACM_STATUS="FAILED"
    exit 1
else
    echo "✓ ACM namespace exists"
    
    # Check MultiClusterHub status
    MCH_STATUS=$(kubectl get multiclusterhub -n open-cluster-management -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$MCH_STATUS" == "Running" ]; then
        echo "✓ MultiClusterHub is Running"
        ACM_STATUS="SUCCESS"
    else
        echo "WARNING: MultiClusterHub status is: $MCH_STATUS (expected: Running)"
        ACM_STATUS="DEGRADED"
        exit 1
    fi
fi
 
 
echo "ACM Deployment Status: $ACM_STATUS"
echo "---------------------"

# Import spoke cluster into ACM if both ACM and spoke are successful
if [ "$ACM_STATUS" == "SUCCESS" ] && [ $SPOKE_EXIT_CODE -eq 0 ]; then
    echo "---------------------"
    echo "Importing spoke cluster into ACM"
    echo "---------------------"
    
    # Ensure we're using the hub cluster kubeconfig
    export KUBECONFIG="$(pwd)/openshift-install-hub/auth/kubeconfig"
    
    # Create ManagedCluster resource with the required label
    cat <<EOF | kubectl apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: coco-spoke
  labels:
    clusterGroup: spoke
    cloud: auto-detect
    vendor: auto-detect
spec:
  hubAcceptsClient: true
EOF
    
    if [ $? -eq 0 ]; then
        echo "✓ ManagedCluster resource created for coco-spoke"
    else
        echo "ERROR: Failed to create ManagedCluster resource"
        exit 1
    fi
    
    # Wait for import secret to be created
    echo "Waiting for import secret to be generated..."
    IMPORT_SECRET_WAIT=0
    while [ $IMPORT_SECRET_WAIT -lt 60 ]; do
        if kubectl get secret -n coco-spoke coco-spoke-import 2>/dev/null; then
            echo "✓ Import secret generated"
            break
        fi
        sleep 5
        IMPORT_SECRET_WAIT=$((IMPORT_SECRET_WAIT + 5))
    done
    
    if [ $IMPORT_SECRET_WAIT -ge 60 ]; then
        echo "ERROR: Timeout waiting for import secret"
        exit 1
    fi
    
    # Extract and apply import manifests to spoke cluster
    echo "Applying import manifests to spoke cluster..."
    kubectl get secret -n coco-spoke coco-spoke-import -o jsonpath='{.data.import\.yaml}' | base64 --decode > /tmp/coco-spoke-import.yaml
    kubectl get secret -n coco-spoke coco-spoke-import -o jsonpath='{.data.crds\.yaml}' | base64 --decode > /tmp/coco-spoke-crds.yaml
    
    # Switch to spoke cluster and apply import manifests
    export KUBECONFIG="$(pwd)/openshift-install-spoke/auth/kubeconfig"
    
    echo "Applying CRDs to spoke cluster..."
    kubectl apply -f /tmp/coco-spoke-crds.yaml
    
    echo "Applying import manifests to spoke cluster..."
    kubectl apply -f /tmp/coco-spoke-import.yaml
    
    # Clean up temporary files
    rm -f /tmp/coco-spoke-import.yaml /tmp/coco-spoke-crds.yaml
    
    # Switch back to hub cluster to verify import
    export KUBECONFIG="$(pwd)/openshift-install-hub/auth/kubeconfig"
    
    echo "Waiting for spoke cluster to be imported and available..."
    IMPORT_WAIT=0
    while [ $IMPORT_WAIT -lt 300 ]; do
        CLUSTER_STATUS=$(kubectl get managedcluster coco-spoke -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null)
        if [ "$CLUSTER_STATUS" == "True" ]; then
            echo "✓ Spoke cluster successfully imported and available in ACM"
            SPOKE_IMPORT_STATUS="SUCCESS"
            break
        fi
        sleep 10
        IMPORT_WAIT=$((IMPORT_WAIT + 10))
        echo "Still waiting... ($IMPORT_WAIT/300 seconds)"
    done
    
    if [ $IMPORT_WAIT -ge 300 ]; then
        echo "WARNING: Spoke cluster import did not complete within 5 minutes"
        echo "Current status: $CLUSTER_STATUS"
        SPOKE_IMPORT_STATUS="TIMEOUT"
    fi
    
    # Verify the label is set correctly
    CLUSTER_LABEL=$(kubectl get managedcluster coco-spoke -o jsonpath='{.metadata.labels.clusterGroup}' 2>/dev/null)
    if [ "$CLUSTER_LABEL" == "spoke" ]; then
        echo "✓ Cluster label 'clusterGroup=spoke' verified"
    else
        echo "WARNING: Cluster label is '$CLUSTER_LABEL' (expected: spoke)"
    fi
    
    # Install required ACM policy addons on spoke cluster
    echo "---------------------"
    echo "Installing ACM policy addons on spoke cluster"
    echo "---------------------"
    
    # Ensure we're using the hub cluster kubeconfig
    export KUBECONFIG="$(pwd)/openshift-install-hub/auth/kubeconfig"
    
    # Create config-policy-controller addon
    cat <<EOF | kubectl apply -f -
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: config-policy-controller
  namespace: coco-spoke
spec:
  installNamespace: open-cluster-management-agent-addon
EOF
    
    # Create governance-policy-framework addon
    cat <<EOF | kubectl apply -f -
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: governance-policy-framework
  namespace: coco-spoke
spec:
  installNamespace: open-cluster-management-agent-addon
EOF
    
    # Create cert-policy-controller addon
    cat <<EOF | kubectl apply -f -
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: cert-policy-controller
  namespace: coco-spoke
spec:
  installNamespace: open-cluster-management-agent-addon
EOF
    
    # Create application-manager addon
    cat <<EOF | kubectl apply -f -
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: application-manager
  namespace: coco-spoke
spec:
  installNamespace: open-cluster-management-agent-addon
EOF
    
    # Wait for addons to become available
    echo "Waiting for addons to become available..."
    ADDON_WAIT=0
    while [ $ADDON_WAIT -lt 180 ]; do
        ADDONS_READY=$(kubectl get managedclusteraddons -n coco-spoke -o jsonpath='{range .items[?(@.spec.installNamespace=="open-cluster-management-agent-addon")]}{.metadata.name}={.status.conditions[?(@.type=="Available")].status}{"\n"}{end}' 2>/dev/null | grep -c "=True" || echo "0")
        if [ "$ADDONS_READY" -ge 4 ]; then
            echo "✓ All policy addons are available"
            ADDON_INSTALL_STATUS="SUCCESS"
            break
        fi
        sleep 10
        ADDON_WAIT=$((ADDON_WAIT + 10))
        echo "Addon status: $ADDONS_READY/4 available ($ADDON_WAIT/180 seconds)"
    done
    
    if [ $ADDON_WAIT -ge 180 ]; then
        echo "WARNING: Some addons may not be fully available yet"
        kubectl get managedclusteraddons -n coco-spoke
        ADDON_INSTALL_STATUS="TIMEOUT"
    fi
    
    echo "---------------------"
else
    echo "Skipping spoke cluster import (ACM: $ACM_STATUS, Spoke Exit Code: $SPOKE_EXIT_CODE)"
    SPOKE_IMPORT_STATUS="SKIPPED"
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

if [ -n "$ACM_STATUS" ]; then
    echo "ACM on hub cluster: $ACM_STATUS"
fi

if [ -n "$SPOKE_IMPORT_STATUS" ]; then
    echo "Spoke cluster import to ACM: $SPOKE_IMPORT_STATUS"
    if [ "$SPOKE_IMPORT_STATUS" == "SUCCESS" ]; then
        echo "  - Cluster name: coco-spoke"
        echo "  - Label: clusterGroup=spoke"
        if [ -n "$ADDON_INSTALL_STATUS" ]; then
            echo "  - Policy addons: $ADDON_INSTALL_STATUS"
            if [ "$ADDON_INSTALL_STATUS" == "SUCCESS" ]; then
                ADDON_COUNT=$(kubectl get managedclusteraddons -n coco-spoke --no-headers 2>/dev/null | wc -l | tr -d ' ')
                echo "  - Total addons installed: $ADDON_COUNT"
            fi
        fi
    fi
fi

echo "---------------------"
echo "done"
echo "---------------------"