#!/bin/sh
set -f
SCS="SnapCenter_Service"
networkCollectionName="sc-aksfwnr"
appruleaksCollectionName="sc-aksfwar"
appruleCollectionName="sc-apprules"
networkrule="network-rule"
applicationrule="application-rule"

# Target FQDN's
targetfqdns=''management.azure.com'
'login.microsoftonline.com'
'api.services.cloud.netapp.com'
'cloud.support.netapp.com.s3.us-west-1.amazonaws.com'
'cognito-idp.us-east-1.amazonaws.com'
'cognito-identity.us-east-1.amazonaws.com'
'sts.amazonaws.com'
'cloud-support-netapp-com-accelerated.s3.amazonaws.com'
'cloudmanagerinfraprod.azurecr.io'
'kinesis.us-east-1.amazonaws.com'
'cloudmanager.cloud.netapp.com'
'netapp-cloud-account.auth0.com'
'support.netapp.com'
'cloud-support-netapp-com.s3.us-west-1.amazonaws.com'
'client.infra.support.netapp.com.s3.us-west-1.amazonaws.com'
'cloud-support-netapp-com-accelerated.s3.us-west-1.amazonaws.com'
'*.blob.core.windows.net'
'exteranl-log.cloudmanager.netapp.com'
'auth0.com'
'registry-1.docker.io'
'auth.docker.io'
'production.cloudflare.docker.com''

httpsport="https=443"
timeurl="ntp.ubuntu.com"
AKSService="AzureKubernetesService"
actionpriority=""

# Usage
show_help() {
  echo "Usage: sh $0 [-h] -fwsubid <Firewall_SubscriptionID> -fwname <Firewall_name> -fwrg <Firewall_Resource_group> -scssubid <${SCS}_SubscriptionID> -scsvnet <${SCS}_VNet_name> -scssubnet <${SCS}_Subnet_name> -scsvnetrg <${SCS}_VNet_Resource_Group> -scsrg <${SCS}_Resource_group>"
  echo "Firewall Configuration for SnapCenter Services in Azure"
  echo "Options:"
  echo "-h              Display this help and exit."
  echo "-fwsubid        Azure Subscription ID of Azure Firewall. If it is same as $SCS subscription, ignore this parameter."
  echo "-fwname         Firewall_name."
  echo "-fwrg           Firewall_Resource_group."
  echo "-scssubid       Azure Subscription ID where you are planning to install $SCS."
  echo "-scsvnet        ${SCS}_VNet_name."
  echo "-scssubnet      ${SCS}_Subnet_name."
  echo "-scsvnetrg      ${SCS}_VNet_Resource_group."
  echo "-scsrg          ${SCS}_Resource_group."
}

while [ $# -gt 0 ]
do
  key="$1"
  case $key in
  -h)
    show_help
    exit 0
    ;;
  -scssubid)
    SCSSubscriptionID=$2
    shift
    shift
    ;;
  -fwsubid)
    FWSubscriptionID=$2
    shift
    shift
    ;;
  -fwname)
    FWName=$2
    shift 2
    ;;
  -fwrg)
    FWRG=$2
    shift 2
    ;;
  -scsvnet)
    SCSVNET=$2
    shift 2
    ;;
  -scsvnetrg)
    SCSVNETRG=$2
    shift 2
    ;;
  -scssubnet)
    SCSSUBNET=$2
    shift 2
    ;;
  -scsrg)
    SCSRG=$2
    shift 2
    ;;
  *)
    echo "Help here"
    show_help >&2
    shift
    exit 1
    ;;
  esac
done

executeAZCommand() {
  cmd=$@
  echo "Executing: $cmd"
  executeCmd=$($cmd 2>&1)
  if [ $? -eq '0' ];then
    echo "Command executed successfully"
  else
    echo "Above command didnt execute successfully. Non Zero exit status: $?, please check"
    echo "Error is $executeCmd, exiting script execution"
    exit 1
  fi
}

validate() {
  if [ -z ${SCSSubscriptionID+x} ]; then
    echo "No $SCS subscriptionID found, please specify $SCS SubscriptionID. Use -scssubid to set $SCS Subscription ID or -h for help."
    exit 1
  fi
  if [ -z ${FWName+x} ]; then
    echo "No firewall name found, please specify Firewall's Name. Use -fwname to set Firewall name or -h for help."
    exit 1
  fi
  if [ -z ${FWRG+x} ]; then
    echo "No firewall resource group found, please specify Firewall's Resource Group. Use -fwrg to set Firewall's Resource Group or -h for help."
    exit 1
  fi
  if [ -z ${SCSVNET+x} ]; then
    echo "No $SCS Vnet name found, please specify $SCS Vnet. Use -scsvnet to set $SCS Vnet or -h for help."
    exit 1
  fi
  if [ -z ${SCSVNETRG+x} ]; then
    echo "No $SCS Vnet Resource Group found, please specify $SCS Vnet Resource Group. Use -scsvnetrg to set $SCS Vnet Resource Group or -h for help."
    exit 1
  fi
  if [ -z ${SCSSUBNET+x} ]; then
    echo "No $SCS Subnet name found, please specify $SCS Subnet Name. Use -scssubnet to set $SCS Subnet or -h for help."
    exit 1
  fi
  if [ -z ${SCSRG+x} ]; then
    echo "No $SCS Resource Group found, please specify $SCS Resource Group. Use -scsrg to set $SCS Resource Group or -h for help."
    exit 1
  fi
  if [ -z ${FWSubscriptionID+x} ]; then
    echo "Firewall subscriptionID is not provided, using $SCS Subscription ID"
  fi
}

checknUpdateSubscriptionID() {
  if [ -z ${FWSubscriptionID+x} ]; then
     FWSubscriptionID=$SCSSubscriptionID
  fi
}

setAZAccountSubscription() {
  # Set azure account
  SubscriptionID=$1
  az account set --subscription "${SubscriptionID}"
#  az account show
}

# Route Table variables
FWROUTE_TABLE_NAME="$SCSRG-SnapCenter-route-table"
FWROUTE_NAME="$SCSRG-SnapCenter-forward-route"
FWROUTE_NAME_INTERNET="$SCSRG-SnapCenter-forward-internet"

fetchFWIPLoc() {
  echo "\nFetching Public IP address ID of firewall: $FWName..."
  cmd="az network firewall show -g $FWRG -n $FWName --query "ipConfigurations[0].publicIpAddress.id" -o tsv"
  executeAZCommand $cmd
  PUBLIC_IP_ID=$executeCmd
  echo "Fetched Public IP ID is $PUBLIC_IP_ID"

  echo "\nFetching Public IP address of firewall: $FWName..."
  cmd="az network public-ip show --ids $PUBLIC_IP_ID --query "ipAddress" -o tsv"
  executeAZCommand $cmd
  FWPUBLIC_IP=$executeCmd
  echo "Fetched Public IP address: $FWPUBLIC_IP"

  echo "\nFetching Private IP address of firewall: $FWName..."
  cmd="az network firewall show -g $FWRG -n $FWName --query "ipConfigurations[0].privateIpAddress" -o tsv"
  executeAZCommand $cmd
  FWPRIVATE_IP=$executeCmd
  echo "Fetched Private IP: $FWPRIVATE_IP"

  echo "\nFetching Location where VNET $SCSVNET is created..."
  setAZAccountSubscription $SCSSubscriptionID
  cmd="az network vnet show -g $SCSVNETRG -n $SCSVNET --query "location" -o tsv"
  executeAZCommand $cmd
  LOC=$executeCmd
  echo "Fetched Location: $LOC"
  setAZAccountSubscription $FWSubscriptionID
}


addExtensionFirewall() {
  # add extension
  echo "\nAdd Azure firewall extension"
  cmd="az extension add --name azure-firewall"
  executeAZCommand $cmd
}

createNetworkRules() {
  echo "\nCheck if firewall network rules exist and if not then creating network rules for $FWName on $FWRG..."
  checkcollection=$(az network firewall network-rule collection show -c $networkCollectionName -g $FWRG -f $FWName 2>/dev/null)
  if [ -z "$checkcollection" ]; then
    echo "Creating Azure firewall network collection $networkCollectionName on $FWName in $FWRG.."
    actionpriority="--action allow --priority 100"
  fi

  destinationaddress="AzureCloud.$LOC"
  echo "Checking if network rule with protocol UDP  and port 1194 on Firewall $FWName present in $FWRG Resource group exists"
  checkapiudprule=$(az network firewall network-rule show --collection-name $networkCollectionName -f $FWName -g $FWRG -n sc-apiudp 2>/dev/null)
  if [ -z "$checkapiudprule" ]; then
    echo "Creating Network rule with protocol UDP  and port 1194 on Firewall $FWName present in $FWRG Resource group..."
    cmd="az network firewall network-rule create -g $FWRG -f $FWName --collection-name $networkCollectionName -n sc-apiudp --protocols UDP --source-addresses * --destination-addresses $destinationaddress --destination-ports 1194 $actionpriority"
    executeAZCommand $cmd
  else
    echo "sc-apiudp network rule for UDP already exists, proceeding"
  fi

  echo "\nChecking if network rule with protocol TCP and port 9000 on Firewall $FWName present in $FWRG Resource group exists"
  checkapitcprule=$(az network firewall network-rule show --collection-name $networkCollectionName -f $FWName -g $FWRG -n sc-apitcp 2>/dev/null )
  if [ -z "$checkapitcprule" ]; then
    echo "Creating Network rule with protocol TCP and port 9000 on Firewall $FWName present in $FWRG Resource group..."
    cmd="az network firewall network-rule create -g $FWRG -f $FWName --collection-name $networkCollectionName -n sc-apitcp --protocols TCP --source-addresses * --destination-addresses $destinationaddress --destination-ports 9000"
    executeAZCommand $cmd
  else
    echo "sc-apitcp network rule for TCP already exists, proceeding"
  fi

  echo "\nChecking if network rule with protocol TCP and port 443 on Firewall $FWName present in $FWRG Resource group exists"
  checkapitcp443rule=$(az network firewall network-rule show --collection-name $networkCollectionName -f $FWName -g $FWRG -n sc-apitcp443 2>/dev/null)
  if [ -z "$checkapitcp443rule" ]; then
    echo "Creating Network rule with protocol TCP and port 443 on Firewall $FWName present in $FWRG Resource group..."
    cmd="az network firewall network-rule create -g $FWRG -f $FWName --collection-name $networkCollectionName -n sc-apitcp443 --protocols TCP --source-addresses * --destination-addresses $destinationaddress --destination-ports 443"
    executeAZCommand $cmd
  else
    echo "sc-apitcp443 network rule for TCP already exists, proceeding"
  fi

  echo "\nchecking if network rule with protocol UDP and port 123 on Firewall $FWName present in $FWRG Resource group exists"
  checktimeudprule=$(az network firewall network-rule show --collection-name $networkCollectionName -f $FWName -g $FWRG -n sc-time 2>/dev/null)
  if [ -z "$checktimeudprule" ]; then
    echo "Creating Network rule with protocol UDP and port 123 on Firewall $FWName present in $FWRG Resource group..."
    cmd="az network firewall network-rule create -g $FWRG -f $FWName --collection-name $networkCollectionName -n sc-time --protocols UDP --source-addresses "*" --destination-fqdns $timeurl --destination-ports 123"
    executeAZCommand $cmd
  else
    echo "sc-time network rule for time-UDP already exists, proceeding..."
  fi
}

createApplicationRules() {
  echo "\nCheck if firewall application rules exist and if not then create application rules in $FWName on $FWRG..."
  checkcollection=$(az network firewall application-rule collection show -c $appruleaksCollectionName -g $FWRG -f $FWName 2>/dev/null)
  if [ -z "$checkcollection" ]; then
    echo "Creating Azure firewall application collection $appruleaksCollectionName on $FWName in $FWRG.."
    actionpriority="--action allow --priority 100"
  fi
  echo "Checking if application rule with service tag AzureKubernetesService and port 443 on Firewall $FWName present in $FWRG Resource group exists"
  checkapprulefqdn=$(az network firewall application-rule show --collection-name $appruleaksCollectionName -f $FWName -g $FWRG -n sc-aksservicetag 2>/dev/null)
  if [ -z "$checkapprulefqdn" ]; then
    echo "Creating Application rule with service tag AzureKubernetesService and port 443 on Firewall $FWName present in $FWRG Resource group..."
    cmd="az network firewall application-rule create -g $FWRG -f $FWName --collection-name $appruleaksCollectionName -n sc-aksservicetag --source-addresses "*" --protocols $httpsport --fqdn-tags $AKSService $actionpriority"
    executeAZCommand $cmd
  else
    echo "sc-aksservicetag application rule already exists, proceeding..."
  fi

  checkcollection=$(az network firewall application-rule collection show -c appruleCollectionName -g $FWRG -f $FWName 2>/dev/null)
  if [ -z "$checkcollection" ]; then
    echo "Creating Azure firewall application collection $appruleCollectionName on $FWName in $FWRG.."
    actionpriority="--action allow --priority 101"
  fi
  echo "\nChecking if firewall application rule with target FQDNs and port 443 on Firewall $FWName present in $FWRG Resource group exists"
  checkapprulescrule=$(az network firewall application-rule show --collection-name $appruleCollectionName -f $FWName -g $FWRG -n sc-apprule 2>/dev/null)
  if [ -z "$checkapprulescrule" ]; then
    echo "Creating Application rule with target FQDNs and port 443 on Firewall $FWName present in $FWRG Resource group..."
    cmd="az network firewall application-rule create -g $FWRG -f $FWName -c $appruleCollectionName -n sc-apprule --source-addresses "*" --protocols $httpsport $actionpriority --target-fqdns $targetfqdns"
    executeAZCommand $cmd
  else
    echo "sc-apprule application rule already exists, proceeding..."
  fi
}

enableDNS(){
  echo "\nChecking if DNS proxy is enabled, if not enable DNS proxy"
  checkDNSProxyEnabled=$(az network firewall show -n bkrscsfw2-firewall -g bkrscsfw2-firewall-rg --query \"Network.DNS.EnableProxy\" 2>/dev/null)
  if [ "$checkDNSProxyEnabled" = \"false\" ]; then
    echo "Enabling DNS proxy on firewall $FWName..."
    cmd="az network firewall update -g $FWRG -n $FWName --enable-dns-proxy true"
    executeAZCommand $cmd
  else
    echo "DNS proxy is enabled on firewall $FWName"
  fi
}

createSCSRG() {
  #SCSRG=$FWRG
  SCSRG_ID=$(az group show -n $SCSRG --query "id" -o tsv 2>/dev/null)
  if [ -z "$SCSRG_ID" ]; then
    echo "\nCreating $SCS Resource group: $SCSRG..."
    az group create -l $LOC -n $SCSRG
  else
    echo "$SCSRG Resource group already exists, proceeding"
  fi

}

createRouteTable() {
  echo "\nChecking if route table: $FWROUTE_TABLE_NAME in RG: $SCSRG exists"
  checkRouteTable=$(az network route-table show --name $FWROUTE_TABLE_NAME -g $SCSRG 2>/dev/null)
  if [ -z "$checkRouteTable" ]; then
    echo "Creating route table: $FWROUTE_TABLE_NAME in RG: $SCSRG..."
    cmd="az network route-table create -g $SCSRG -l $LOC --name $FWROUTE_TABLE_NAME"
    executeAZCommand $cmd
  else
    echo "Route table $FWROUTE_TABLE_NAME already exists, proceeding..."
  fi

  echo "\nChecking if route: $FWROUTE_NAME exists"
  checkRoute=$(az network route-table route show --route-table-name $FWROUTE_TABLE_NAME -n $FWROUTE_NAME -g $SCSRG 2>/dev/null)
  if [ -z "$checkRoute" ]; then
    echo "Creating route: $FWROUTE_NAME"
    cmd="az network route-table route create -g $SCSRG --name $FWROUTE_NAME --route-table-name $FWROUTE_TABLE_NAME --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $FWPRIVATE_IP --subscription $SubscriptionID"
    executeAZCommand $cmd
  else
    echo "Route $FWROUTE_NAME already exists, proceeding..."
  fi

  echo "\nChecking if route: $FWROUTE_NAME_INTERNET exists"
  checkRouteInternet=$(az network route-table route show --route-table-name $FWROUTE_TABLE_NAME -n $FWROUTE_NAME_INTERNET -g $SCSRG 2>/dev/null)
  if [ -z "$checkRouteInternet" ]; then
    echo "Creating route: $FWROUTE_NAME_INTERNET"
    addressPrefix="$FWPUBLIC_IP/32"
    cmd="az network route-table route create -g $SCSRG --name $FWROUTE_NAME_INTERNET --route-table-name $FWROUTE_TABLE_NAME --address-prefix $addressPrefix --next-hop-type Internet"
    executeAZCommand $cmd
  else
    echo "Route $FWROUTE_NAME_INTERNET already exists, proceeding..."
  fi
}

updateSCSSubnetWithRouteTable() {
  echo "\nFetching route table id..."
  cmd="az network route-table show -g $SCSRG --name $FWROUTE_TABLE_NAME --query "id" -o tsv"
  executeAZCommand $cmd
  ROUTE_TABLE_ID=$executeCmd
  echo "Fetched route table id: $ROUTE_TABLE_ID"

  echo "\nAttach route table $ROUTE_TABLE_ID to subnet $SCSSUBNET"
  cmd="az network vnet subnet update -g $SCSVNETRG --vnet-name $SCSVNET --name $SCSSUBNET --route-table $ROUTE_TABLE_ID"
  executeAZCommand $cmd
}

# Validate the arguments provided
validate
#Check if Firewall Subscription ID is not provided, then update the subscription ID same as SCS
checknUpdateSubscriptionID
# Set Azure Account SubscriptionID in which Firewall is created.
setAZAccountSubscription $FWSubscriptionID
# Add Firewall Extension
addExtensionFirewall
# Enable DNS for firewall
enableDNS
# Fetch Firewall configuration
fetchFWIPLoc
# Create Network rules
createNetworkRules
# Create Application rules
createApplicationRules

# Set Azure Account SubscriptionID in which SCS is to be installed.
setAZAccountSubscription $SCSSubscriptionID
#Create SnapCenter Services resource group
createSCSRG
# Create Route tables and routes
createRouteTable
# Update SnapCenterServices with route table
updateSCSSubnetWithRouteTable
echo "\nSuccessfully updated firewall configuration for SnapCenter Service. A route table $FWROUTE_TABLE_NAME was created and attached to the subnet $SCSSUBNET of Vnet $SCSVNET"
set +f