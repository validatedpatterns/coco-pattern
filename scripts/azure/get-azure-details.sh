# Get the ARO created RG
# ENSURE YOU ARE LOGGED INTO
echo "You need to be logged into the cluster and azure"
AZURE_RESOURCE_GROUP=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')

# Get VNET name used by ARO. This exists in the admin created RG
ARO_VNET_NAME=$(az network vnet list --resource-group $AZURE_RESOURCE_GROUP --query "[].{Name:name}" --output tsv)

# Get the OpenShift worker subnet ip address cidr. This exists in the admin created RG
ARO_WORKER_SUBNET_ID=$(az network vnet subnet list --resource-group $AZURE_RESOURCE_GROUP --vnet-name $ARO_VNET_NAME --query "[].{Id:id} | [? contains(Id, 'worker')]" --output tsv)

ARO_NSG_ID=$(az network nsg list --resource-group $AZURE_RESOURCE_GROUP --query "[].{Id:id}" --output tsv)

echo "AZURE_REGION: \"$AZURE_REGION\""
echo "AZURE_RESOURCE_GROUP: \"$AZURE_RESOURCE_GROUP\""
echo "AZURE_SUBNET_ID: \"$ARO_WORKER_SUBNET_ID\""
echo "AZURE_NSG_ID: \"$ARO_NSG_ID\""
