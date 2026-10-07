
#!/usr/bin/env bash
set -e

# Function to detect available Python 3 binary.
get_python_cmd() {
    local python_cmd
    if command -v python3 &> /dev/null; then
        python_cmd="python3"
    elif command -v python &> /dev/null; then
        python_cmd="python"
    else
        echo "ERROR: Neither python3 nor python is available" >&2
        exit 1
    fi

    if ! "$python_cmd" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
        echo "ERROR: Python 3.10 or later is required" >&2
        exit 1
    fi
    echo "$python_cmd"
} 

# Parse arguments
AZUREREGION=""
RECREATE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --recreate)
            RECREATE=true
            shift
            ;;
        -*)
            echo "Error: Unknown option $1"
            echo "Usage: $0 [--recreate] {azure-region-code}"
            echo "Example: $0 eastasia"
            exit 1
            ;;
        *)
            if [ -z "$AZUREREGION" ]; then
                AZUREREGION="$1"
            else
                echo "Error: Too many positional arguments."
                echo "Usage: $0 [--recreate] {azure-region-code}"
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$AZUREREGION" ]; then
    echo "Error: Azure region is required."
    echo "Usage: $0 [--recreate] {azure-region-code}"
    echo "Example: $0 eastasia"
    exit 1
fi

echo "---------------------"
echo "Validating configuration"
echo "---------------------"

# Check if values-global.yaml exists
if [ ! -f "values-global.yaml" ]; then
    echo "ERROR: values-global.yaml file not found in current directory"
    echo "Please run this script from the root directory of the project"
    exit 1
fi


# Extract clusterGroupName from values-global.yaml using yq
CLUSTER_GROUP_NAME=$(yq eval '.main.clusterGroupName' values-global.yaml)


echo "Check your cluster group name makes sense: clusterGroupName = $CLUSTER_GROUP_NAME"

echo "Run from the root directory of the project"
echo "\n"
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
PYTHON_CMD=$(get_python_cmd)
"$PYTHON_CMD" -m pip install -r requirements.txt
echo "---------------------"
echo "requirements installed"
echo "---------------------"
sleep 5

# The OpenShift pull secret and SSH public key locations are resolved by
# rhdp-cluster-define.py below (with clear error messages if not found).
# Override via the PULL_SECRET / SSH_PUBLIC_KEY environment variables if
# your pull secret or SSH key isn't at the default location.

echo "---------------------"
echo "defining cluster"
echo "---------------------"
DEFINE_ARGS=()
if [ "$RECREATE" = true ]; then
    DEFINE_ARGS+=(--recreate)
fi
$PYTHON_CMD rhdp/rhdp-cluster-define.py "${DEFINE_ARGS[@]}" ${AZUREREGION}
echo "---------------------"
echo "cluster defined"
echo "---------------------"
sleep 10
echo "---------------------"
echo "openshift-install"
echo "---------------------"
openshift-install create cluster --dir=./openshift-install
echo "openshift-install done"
