oc get -n openshift-config secret/pull-secret -o json | jq -r '.data.".dockerconfigjson"' | base64 -d | jq "." > pull-secret-pretty.json
