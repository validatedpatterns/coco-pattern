POD_MAC=$(oc get pod coco-demo-insecure-kata -o json |  jq -r '.metadata.annotations["k8s.ovn.org/pod-networks"] | fromjson | .default.mac_address')
echo $POD_MAC
