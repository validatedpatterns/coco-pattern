# Running tests

## Prerequisites

* Openshift cluster with coco-pattern installed
* kubeconfig file for Openshift cluster
* oc client installed at ~/oc_client/oc

## Steps

* create python3 venv, clone multicloud-gitops repository
* export KUBECONFIG=\<path to hub kubeconfig file>
* export INFRA_PROVIDER=azure
* (optional) export WORKSPACE=\<dir to save test results to> (defaults to /tmp)
* cd coco-pattern/tests/interop
* pip install -r requirements.txt
* ./run_tests.sh

## Results

* results .xml files will be placed at $WORKSPACE
* test logs will be placed at $WORKSPACE/.results/test_execution_logs/
* CI badge file will be placed at $WORKSPACE
