
========= PRIVATE AKS with PE sharing AKS VNet =========
#powershell 
$resourceGroup="privateep-sharedvnet-rg"
$aksResourceGroup="aks-private"
$aksClusterName="aks-private"
$storageAccountName="saprivatesharedvnet"
$PESubnetName="pe-subnet"
$region="eastus"
$subnetPrefix='10.225.0.0/24'
$StoragePrivateEndpoint="StoragePESharedVNet"
$PrivateLinkNameSharedVNet="privatelink.blob.core.windows.net"

# Create resource group
az group create --name $resourceGroup --location $region

# Create storage account 
az storage account create --name $storageAccountName --resource-group $resourceGroup --location $region --sku Standard_LRS
# Create container in above SA
$storageAccountKey = az storage account keys list --resource-group $resourceGroup --account-name $storageAccountName --query '[0].value' --output tsv
az storage container create --name "container01" --account-name $storageAccountName --account-key $storageAccountKey
# Block public access after container creation
az storage account update --name $storageAccountName --resource-group $resourceGroup --public-network-access Disabled

# Disable public FQDN on existing AKS Private cluster
az aks update -n $aksClusterName -g $resourceGroup --disable-public-fqdn

# Get Private AKS VNet
$aksMCResourceGroup=az aks show --resource-group $aksResourceGroup --name $aksClusterName --query "nodeResourceGroup" --output tsv
$vnetInfo=az network vnet list --resource-group $aksMCResourceGroup --query '[0].{name:name, id:id}' --output json | ConvertFrom-Json
$aksVnetId=$vnetInfo.id
$aksVnetName=$vnetInfo.name
echo $aksVnetName

# Create Storage PE subnet on AKS VNet and get Subnet ID
az network vnet subnet create --name $PESubnetName --resource-group $aksMCResourceGroup --vnet-name $aksVnetName --address-prefixes $subnetPrefix --disable-private-endpoint-network-policies true
$PESubnetId = az network vnet subnet show --resource-group $aksMCResourceGroup --vnet-name $aksVnetName  --name $PESubnetName --query 'id' --output tsv
echo $PESubnetId

# Create a Private Endpoint for the Storage Account using Subnet ID of Storage PE
az network private-endpoint create `
    --resource-group $resourceGroup `
    --name $StoragePrivateEndpoint `
    --vnet-name $aksVnetName `
    --subnet $PESubnetId `
    --private-connection-resource-id $(az storage account show --name $storageAccountName --resource-group $resourceGroup --query "id" --output tsv) `
    --group-ids "blob" `
    --connection-name "StoragePESharedVNetConnection"

# Create a Private DNS Zone to associate with Storage PE
az network private-dns zone create --resource-group $resourceGroup --name $PrivateLinkNameSharedVNet

# Link AKS VNet to the Private DNS Zone. Using $aksVnetId, private-link will be in different RG than AKS Vnet (in MC Resource Group)
az network private-dns link vnet create --resource-group $resourceGroup --virtual-network $aksVnetId --name "AksPrivateDnsLink" --zone-name "$PrivateLinkNameSharedVNet" --registration-enabled false

# Add A-record pointing to Storage PE
## Get the Private IP Address of the Storage Private Endpoint:
$privateIpAddress = az network private-endpoint show --name $StoragePrivateEndpoint --resource-group $resourceGroup --query 'customDnsConfigs[0].ipAddresses[0]' --output tsv
echo $privateIpAddress

## Add the A-Record of Storage PE to the Private DNS Zone table
az network private-dns record-set a add-record --resource-group $resourceGroup --zone-name $PrivateLinkNameSharedVNet --record-set-name $storageAccountName --ipv4-address $privateIpAddress



# Test to validate AZ CLI access from AKS Pod
$yaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: storage-connectivity-tester
spec:
  containers:
  - name: azure-cli
    image: mcr.microsoft.com/azure-cli
    command:
      - sleep
      - "3600"
"@

$yaml | kubectl apply -f -

k exec storage-connectivity-tester -it -- bash

# from cli run below
## Test to validate NW connectivity to storage account from AKS Pod
PrivateLinkNameSharedVNet="privatelink.blob.core.windows.net"
storageAccountName="saprivatesharedvnet"

nslookup $storageAccountName.$PrivateLinkNameSharedVNet

## Test for Storage connectivity
az login

resourceGroup="privateep-sharedvnet-rg"
storageAccountName="saprivatesharedvnet"
storageAccountKey=$(az storage account keys list --resource-group $resourceGroup --account-name $storageAccountName --query '[0].value' --output tsv)
echo $storageAccountKey

# List the containers in the storage account 
az storage container list --account-name $storageAccountName --account-key $storageAccountKey


# Test to validate File mount using Blob CSI driver
$yaml = @"
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: statefulset-blob-nfs
  labels:
    app: nginx
spec:
  serviceName: statefulset-blob-nfs
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: statefulset-blob-nfs
        image: mcr.microsoft.com/oss/nginx/nginx:1.19.5
        command:
        - "/bin/sh"
        - "-c"
        - while true; do echo $(date) >> /mnt/azureblob/data; sleep 60; done
        volumeMounts:
        - name: persistent-storage
          mountPath: /mnt/azureblob
  volumeClaimTemplates:
  - metadata:
      name: persistent-storage
      annotations:
        volume.beta.kubernetes.io/storage-class: azureblob-nfs-premium
    spec:
      accessModes: ["ReadWriteMany"]
      resources:
        requests:
          storage: 100Gi
"@

$yaml | kubectl apply -f -

k get pods,pv,pvc

# Delete resource group on completion
az group delete --name $resourceGroup --yes --no-wait

----
az aks command invoke -g $resourceGroup -n $aksClusterName --command "kubectl get nodes"
az aks update -n $aksClusterName -g $resourceGroup --enable-blob-driver


========= PRIVATE AKS with PE in dedicated VNet =========
#powershell 
$resourceGroup="privateep-dedicatedvnet-rg"
$aksResourceGroup="aks-private"
$aksClusterName="aks-private"
$storageAccountName="saprivatededicatedvnet"
$PEVNetName="pe-vnet"
$PESubnetName="pe-subnet"
$region="eastus"
$vnetPrefix='10.208.0.0/12'
$subnetPrefix='10.208.0.0/14'
$StoragePrivateEndpoint="StoragePEDedicatedVNet"
$PrivateLinkNameDedicatedVNet="privatelink.blob.core.windows.net"

# Create resource group
az group create --name $resourceGroup --location $region

# Create storage account 
az storage account create --name $storageAccountName --resource-group $resourceGroup --location $region --sku Standard_LRS
# Create container in above SA
$storageAccountKey = az storage account keys list --resource-group $resourceGroup --account-name $storageAccountName --query '[0].value' --output tsv
az storage container create --name "container01" --account-name $storageAccountName --account-key $storageAccountKey
# Block public access after container creation
az storage account update --name $storageAccountName --resource-group $resourceGroup --public-network-access Disabled

#az aks get-credentials -n $aksClusterName -g $resourceGroup --overwrite-existing

#Disable public FQDN on existing AKS Private cluster
#az aks update -n $aksClusterName -g $resourceGroup --disable-public-fqdn

# Create a new PE VNet 
az network vnet create --resource-group $resourceGroup --name $PEVNetName --address-prefix $vnetPrefix --location $region

# Create a subnet within the VNet dedicated for the private endpoint
az network vnet subnet create --resource-group $resourceGroup --vnet-name $PEVNetName --name $PESubnetName --address-prefix $subnetPrefix --disable-private-endpoint-network-policies true --disable-private-link-service-network-policies true
$PESubnetId = az network vnet subnet show --resource-group $resourceGroup --vnet-name $PEVNetName --name $PESubnetName --query 'id' --output tsv
echo $PESubnetId

# Create a Private Endpoint for the Storage Account using Subnet ID of Storage PE
az network private-endpoint create `
    --resource-group $resourceGroup `
    --name $StoragePrivateEndpoint `
    --vnet-name $PEVNetName `
    --subnet $PESubnetId `
    --private-connection-resource-id $(az storage account show --name $storageAccountName --resource-group $resourceGroup --query "id" --output tsv) `
    --group-ids "blob" `
    --connection-name "StoragePEDedicatedVNetConnection"

# Create a Private DNS Zone to associate with Storage PE
az network private-dns zone create --resource-group $resourceGroup --name $PrivateLinkNameDedicatedVNet

# Link AKS VNet to the Storage Private DNS Zone. Using $aksVnetId, private-link will be in different RG than AKS Vnet (in MC Resource Group)
## Get Private AKS VNet
$aksMCResourceGroup=az aks show --resource-group $aksResourceGroup --name $aksClusterName --query "nodeResourceGroup" --output tsv
$vnetInfo=az network vnet list --resource-group $aksMCResourceGroup --query '[0].{name:name, id:id}' --output json | ConvertFrom-Json
$aksVnetId=$vnetInfo.id
$aksVnetName=$vnetInfo.name
echo $aksVnetName

az network private-dns link vnet create --resource-group $resourceGroup --virtual-network $aksVnetId --name "AksPrivateDnsLink" --zone-name $PrivateLinkNameDedicatedVNet --registration-enabled false

# Add A-record pointing to Storage PE
## Get the Private IP Address of the Storage Private Endpoint:
$privateIpAddress = az network private-endpoint show --name $StoragePrivateEndpoint --resource-group $resourceGroup --query 'customDnsConfigs[0].ipAddresses[0]' --output tsv
## Add the A-Record of Storage PE to the Private DNS Zone table
az network private-dns record-set a add-record --resource-group $resourceGroup --zone-name $PrivateLinkNameDedicatedVNet --record-set-name $storageAccountName --ipv4-address $privateIpAddress

# Create VNet peering between AKS and Storage VNets
## Create VNet Peering from AKS VNet to Storage VNet
az network vnet peering create --name peer-aks-storage --resource-group $aksMCResourceGroup --vnet-name $aksVnetName --remote-vnet $(az network vnet show --resource-group $resourceGroup --name $PEVNetName --query id -o tsv) --allow-vnet
 
## Create VNet Peering from Storage VNet to AKS VNet 
az network vnet peering create --name peer-storage-aks --resource-group $resourceGroup --vnet-name $PEVNetName --remote-vnet $(az network vnet show --resource-group $aksMCResourceGroup --name $aksVnetName --query id --out tsv) --allow-vnet-access

## Verification of VNet Peering should say 'Connected'
# Check peering status for AKS VNet
az network vnet peering show --name peer-aks-storage --resource-group $aksMCResourceGroup --vnet-name $aksVnetName --query peeringState

# Check peering status for Storage VNet
az network vnet peering show --name peer-storage-aks --resource-group $resourceGroup --vnet-name $PEVNetName --query peeringState


# Test to validate NW connectivity to storage account from AKS Pod
PrivateLinkNameSharedVNet="privatelink.blob.core.windows.net"
storageAccountName="saprivatededicatedvnet"
nslookup $storageAccountName.$PrivateLinkNameSharedVNet
	
# from cli run below
az login

resourceGroup="privateep-dedicatedvnet-rg"
storageAccountName="saprivatededicatedvnet"
storageAccountKey=$(az storage account keys list --resource-group $resourceGroup --account-name $storageAccountName --query '[0].value' --output tsv)
echo $storageAccountKey

# List the containers in the storage account 
az storage container list --account-name $storageAccountName --account-key $storageAccountKey

# Delete resource group on completion
az group delete --name $resourceGroup --yes --no-wait

---
## (Do this ONLY if Storage Account VNet is diff from AKS VNet) Link Storage Account VNet to the Private DNS Zone
#$PEVnetName=($PESubnetId -split '/')[-3]
#$PEVnetId = az network vnet show --name $PEVnetName --resource-group $resourceGroup --query 'id' --output tsv
#az network private-dns link vnet create --resource-group $resourceGroup --virtual-network $PEVnetId --name "StoragePrivateDnsLink" --zone-name $PrivateLinkNameDedicatedVNet --registration-enabled false



   