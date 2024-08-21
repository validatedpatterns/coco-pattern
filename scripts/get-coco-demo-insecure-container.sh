
oc get pods coco-demo-insecure -o json | jq -r '.metadata.uid'