## 

oc login 

oc get pods coco-demo-insecure -o json | jq -r '.metadata.uid'

oc get nodes

oc debug node/dell-per760-29.lab.eng.pek2.redhat.com

chroot /host

df | grep "UID"

cd TO_DIRECTORY/keys/

less *.txt

## 

oc login

sh get-coco-demo-insecure-kata-mac.sh --- POD PID

oc debug node/dell-per760-29.lab.eng.pek2.redhat.com

sudo su


podman run -it --privileged --pid=host quay.io/rh-ee-chbutler/coredumps:latest bash

export POD_PID=0a:58:0a:80:00:4e

PID=$(ps aux | grep qemu | grep -i "$POD_MAC" | awk '{print $2}')



gcore $PID

strings core.$PID | grep -i MyMagicKeyIsABanana -c


## 

oc login

sh get-coco-demo-mac.sh --- POD MACexport 

oc debug node/dell-per760-29.lab.eng.pek2.redhat.com

sudo su

podman run -it --privileged --pid=host quay.io/rh-ee-chbutler/coredumps:latest bash

export POD_PID=0a:58:0a:80:00:4e

PID=$(ps aux | grep qemu | grep -i "$POD_MAC" | awk '{print $2}')



gcore $PID

strings core.$PID | grep -i MyMagicKeyIsABanana -c