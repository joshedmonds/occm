#!/bin/bash

validate() {
  echo "The script takes around 4 to 5 minutes as role creation and assignments take time to reflect."
  if [ -z ${SubscriptionID+x} ]; then
    echo "No subscriptionID found, please specify connector's SubscriptionID. Use -s to set SubscriptionID or -h for help."
    exit 1
  fi
  if [ -z ${ConnectorName+x} ]; then
    echo "No Connector name found, please specify Connector Name. Use -c to set ConnectorName or -h for help."
    exit 1
  fi
  if [ -z ${ResourceGroup+x} ]; then
    echo "No resource group found, please specify connector's ResourceGroup Name. Use -g to set ResourceGroup or -h for help."
    exit 1
  fi
}

# Usage
show_help() {
  cat <<EOF
Usage: sh prerequisite_azure.sh [-h] -s <SubscriptionID> -g <ResourceGroup> -c <ConnectorName>...
Enable prerequisites to install SnapCenter Service in AZURE

    -h                  display this help and exit
    -s SubscriptionID   connector's subscriptionID.
    -g ResourceGroup    connector's ResourceGroup Name.
    -c ConnectorName    connector VM Name.
EOF
}

createUserMSI() {

  #prepare msi name
  userMSIName="SnapCenter-MSI-"${ConnectorName}

  #set az account
  az account set --subscription "${SubscriptionID}"

  #Create user managed identity under the given service connector's resource group
  userMSIPrincipleID=$(az identity create -g "$ResourceGroup" -n "$userMSIName" --query 'principalId' -o tsv)

  if [ -z "$userMSIPrincipleID" ]; then
    echo "Failed to create the user managed identity."
    exit 1
  fi

  echo -e "User managed identity created, User MSI Name: " "${userMSIName}" "\n"

}

createManagedClusterRole() {
  #prepare managed cluster role name
  strhypen="-"
  ManagedClusterRoleName="SnapCenter-AKS-Cluster-Admin-"${ResourceGroup}${strhypen}${ConnectorName}

  permissions=""'"Microsoft.Resources/subscriptions/resourceGroups/read"'",
               "'"Microsoft.ContainerService/managedClusters/write"'",
			   "'"Microsoft.ContainerService/managedClusters/read"'",
			   "'"Microsoft.ManagedIdentity/userAssignedIdentities/assign/action"'",
			   "'"Microsoft.ManagedIdentity/userAssignedIdentities/read"'",
			   "'"Microsoft.ContainerService/managedClusters/delete"'",
			   "'"Microsoft.Compute/virtualMachines/read"'",
			   "'"Microsoft.Network/networkInterfaces/read"'",
			   "'"Microsoft.ContainerService/managedClusters/listClusterUserCredential/action"'""
  #prepare service connector rg scope
  rgScope="/subscriptions/$SubscriptionID/resourceGroups/"${ResourceGroup}
  echo "Service connector's resource group scope: " "$rgScope"

  # check if role already exists and update
  sleep 30
  ManagedClusterRoleDefID=$(az role definition list --custom-role-only true -n "$ManagedClusterRoleName" --scope "$rgScope" --subscription "$SubscriptionID" --query [0].id -o tsv)

  if [ ! -z "$ManagedClusterRoleDefID" ]; then
  echo "custom role '$ManagedClusterRoleName' already exists. Updating.."
  res=$(az role definition update --role-definition '{
		"roleName": "'"$ManagedClusterRoleName"'",
		"Description": "SnapCenter AKS cluster management role",
		"id": "'"$ManagedClusterRoleDefID"'",
		"roleType": "CustomRole",
		"type": "Microsoft.Authorization/roleDefinitions",
		"Actions": ['"$permissions"'],
		"DataActions": [],
		"NotDataActions": [],
		"AssignableScopes": ["'"$rgScope"'"]
	}' --query 'id' -o tsv)
	if [ -z "$res" ]; then
		echo -e "Failed to update the custom role: '$ManagedClusterRoleName'" "\n"
		exit 1
	fi
	echo -e "custom role updated successfully, RoleDefinitionID:" "$ManagedClusterRoleDefID" "\n"
	return
  fi


  #create custom role snapcenter managed cluster at rg scope
  ManagedClusterRoleDefID=$(az role definition create --role-definition '{
	  "Name":"'"$ManagedClusterRoleName"'",
	  "IsCustom": true,
	  "Description": "SnapCenter AKS cluster management role",
	  "Actions": ['"$permissions"'],
	  "NotActions": [],
	  "AssignableScopes": ["'"$rgScope"'"]
	}' --query 'id' -o tsv)

  if [ -z "$ManagedClusterRoleDefID" ]; then
    echo "Failed to create the custom role: '$ManagedClusterRoleName'"
    exit 1
  fi

  echo -e "custom role '$ManagedClusterRoleName' created, RoleDefinitionID:" "$ManagedClusterRoleDefID" "\n"

}

createNetworkManagementRole() {
  #prepare managed cluster role name
  strhypen="-"
  NetworkManagementRoleName="SnapCenter-Network-Management-"${ResourceGroup}${strhypen}${ConnectorName}

  #Get service connector's subnet scope
  nic=$(az vm show -n "$ConnectorName" -g "$ResourceGroup" --query 'networkProfile.networkInterfaces[0].id' -o tsv)

  if [ -z "$nic" ]; then
    echo -e "Failed to get the network details" "\n"
    exit 1
  fi

  echo "NIC:""$nic"

  subnetScope=$(az vm nic show -g "$ResourceGroup" --vm-name "$ConnectorName" --nic "$nic" --query 'ipConfigurations[0].subnet.id' -o tsv)

  #get network subscriptionID
  networkSubscriptionID=$(echo "$subnetScope" | cut -d'/' -f 3)

  echo "networkSubscriptionID: " "$networkSubscriptionID"

  #get network resourcegroup
  networkResourceGroup=$(echo "$subnetScope" | cut -d'/' -f 5)
  echo "networkResourceGroup: " "$networkResourceGroup"

  #get network vnet name
  virtualNetworkName=$(echo "$subnetScope" | cut -d'/' -f 9)
  echo "virtualNetworkName: " "$virtualNetworkName"

  #prepare vnet scope
  vnetScope="/subscriptions/$networkSubscriptionID/resourceGroups/$networkResourceGroup/providers/Microsoft.Network/virtualNetworks/$virtualNetworkName"
  echo "vnetScope: " "$vnetScope"

  permissions=""'"Microsoft.Network/virtualNetworks/subnets/read"'",
			"'"Microsoft.Authorization/roleAssignments/read"'",
			"'"Microsoft.Network/virtualNetworks/subnets/join/action"'",
			"'"Microsoft.Network/virtualNetworks/read"'",
			"'"Microsoft.Network/virtualNetworks/join/action"'""

  # check if role already exists
  sleep 30
  NetworkRoleDefID=$(az role definition list --custom-role-only true -n "$NetworkManagementRoleName" --scope $vnetScope --subscription "$networkSubscriptionID" --query [0].id -o tsv)

  if [ ! -z "$NetworkRoleDefID" ]; then
  echo "custom role '$NetworkManagementRoleName' already exists. updating.."
  res=$(az role definition update --role-definition '{
		"roleName": "'"$NetworkManagementRoleName"'",
		"Description": "SnapCenter AKS network management role",
		"id": "'"$NetworkRoleDefID"'",
		"roleType": "CustomRole",
		"type": "Microsoft.Authorization/roleDefinitions",
		"Actions": ['"$permissions"'],
		"DataActions": [],
		"NotDataActions": [],
		"AssignableScopes": ["'"$vnetScope"'"]
	}' --query 'id' -o tsv)
	if [ -z "$res" ]; then
		echo -e "Failed to update the custom role: '$NetworkManagementRoleName'" "\n"
		exit 1
	fi
	echo -e "custom role updated successfully, RoleDefinitionID:" "$NetworkRoleDefID" "\n"
	return
  fi

  #create snapcenter network management custom role at occm vnet scope
  NetworkRoleDefID=$(az role definition create --role-definition '{
	  "Name": "'"$NetworkManagementRoleName"'",
	  "IsCustom": true,
	  "Description": "SnapCenter AKS network management role",
	  "Actions": ['"$permissions"'],
	  "NotActions": [],
	  "AssignableScopes": ["'"$vnetScope"'"]
	}' --query 'id' -o tsv)

  if [ -z "$NetworkRoleDefID" ]; then
    echo "Failed to create the custom role: '$NetworkManagementRoleName'"
    exit 1
  fi

  echo -e "custom role '$NetworkManagementRoleName' created, RoleDefinitionID:" "$NetworkRoleDefID" "\n"
}

createUDRRole(){

  #get network vnet name
  subnetName=$(echo "$subnetScope" | cut -d'/' -f 11)
  routeTableScope=$(az network vnet subnet show -g "$networkResourceGroup" -n "$subnetName" --vnet-name "$virtualNetworkName" --query 'routeTable.id' -o tsv)

  if [ -z "$routeTableScope" ]; then
    echo -e "Route table not configured in subnet. Exit role creation" "\n"
    return
  fi

  # check if role already exists
  sleep 30
  routeTableName=$(echo "$routeTableScope" | cut -d'/' -f 9)
  routeTableSubscriptionID=$(echo "$routeTableScope" | cut -d'/' -f 3)
  #prepare route route table management role name
  routTableManagementRoleName="SnapCenter-UDR-Management-"${ResourceGroup}${strhypen}${ConnectorName}

  permissions=""'"Microsoft.Network/routeTables/*"'",
			"'"Microsoft.Network/networkInterfaces/effectiveRouteTable/action"'",
			"'"Microsoft.Network/networkWatchers/nextHop/action"'""

  RouteTableRoleDefID=$(az role definition list --custom-role-only true -n "$routTableManagementRoleName" --scope "$routeTableScope" --subscription "$routeTableSubscriptionID" --query [0].id -o tsv)

  if [ ! -z "$RouteTableRoleDefID" ]; then
  echo "custom role '$routTableManagementRoleName' already exists. updating.."
  res=$(az role definition update --role-definition '{
		"roleName": "'"$routTableManagementRoleName"'",
		"Description": "SnapCenter AKS UDR management role",
		"id": "'"$RouteTableRoleDefID"'",
		"roleType": "CustomRole",
		"type": "Microsoft.Authorization/roleDefinitions",
		"Actions": ['"$permissions"'],
		"DataActions": [],
		"NotDataActions": [],
		"AssignableScopes": ["'"$routeTableScope"'"]
	}' --query 'id' -o tsv)
	if [ -z "$res" ]; then
		echo -e "Failed to update the custom role: '$routTableManagementRoleName'" "\n"
		exit 1
	fi
	echo -e "custom role updated successfully, RoleDefinitionID:" "$RouteTableRoleDefID" "\n"
	return
  fi

  #create snapcenter udr management custom role at udr scope
  RouteTableRoleDefID=$(az role definition create --role-definition '{
	  "Name": "'"$routTableManagementRoleName"'",
	  "IsCustom": true,
	  "Description": "SnapCenter AKS UDR management role",
	  "Actions": ['"$permissions"'],
	  "NotActions": [],
	  "AssignableScopes": ["'"$routeTableScope"'"]
	}' --query 'id' -o tsv)

  if [ -z "$RouteTableRoleDefID" ]; then
    echo -e "Failed to create the custom role: '$routTableManagementRoleName'" "\n"
    exit 1
  fi

  echo -e "custom role '$routTableManagementRoleName' created, RoleDefinitionID:" "$routeTableSubscriptionID" "\n"
}

createPrivateDNSZone() {
  #check if its a public cluster
  publicIps=$(az vm show -g "$ResourceGroup" -d -n "$ConnectorName" --query publicIps -otsv)
  #if public ips of a vm is empty then its a private connector
  if [ ! -z "$publicIps" ]; then
     echo -e "connector is public. Exit creating private DNS Zone." "\n"
    return
  fi
  #create private dns zone.
  location=$(az group show -g "$ResourceGroup" --query location  -o tsv)
  dnsZoneName="privatelink.$location.azmk8s.io"

  #check if the zone exists.
  #Using the list command here instead of show. The show command redirects the error to the output and is not best for user experience
  res=$(az network private-dns zone list -g "$ResourceGroup" --query "[?name=='$dnsZoneName']" --output table)
  if [ ! -z "$res" ]; then
    echo -e "private DNS zone exists. Exit creating private DNS Zone." "\n"
    return
  fi

  #create DNS Zone
  result=$(az network private-dns zone create --name "$dnsZoneName" --resource-group "$ResourceGroup")
  if [ ! -z "$result" ]; then
    echo -e "Private DNS zone created successfully." "\n"
    return
  fi
}

createPrivateDNSRole(){

  if [ -z "$dnsZoneName" ]; then
    echo -e "connector is public. Exit creating private DNS zone management role" "\n"
	return
  fi

  dnsZoneScope="/subscriptions/$SubscriptionID/resourceGroups/$ResourceGroup/providers/Microsoft.Network/privateDnsZones/$dnsZoneName"
  # check if DNS Zone management role already exists
  sleep 30

  DNSZoneManagementRoleName="SnapCenter-DNSZone-Management-"${ResourceGroup}${strhypen}${ConnectorName}

  DNSZoneRoleDefID=$(az role definition list --custom-role-only true -n "$DNSZoneManagementRoleName" --scope "$dnsZoneScope" --subscription "$SubscriptionID" --query [0].id -o tsv)

  permissions=""'"Microsoft.Network/privateDnsZones/*"'""

  if [ ! -z "$DNSZoneRoleDefID" ]; then
  echo "custom role '$DNSZoneManagementRoleName' already exists. updating..."
  res=$(az role definition update --role-definition '{
		"roleName": "'"$DNSZoneManagementRoleName"'",
		"Description": "SnapCenter AKS DNS Zone management role",
		"id": "'"$DNSZoneRoleDefID"'",
		"roleType": "CustomRole",
		"type": "Microsoft.Authorization/roleDefinitions",
		"Actions": ['"$permissions"'],
		"DataActions": [],
		"NotDataActions": [],
		"AssignableScopes": ["'"$dnsZoneScope"'"]
	}' --query 'id' -o tsv)
	if [ -z "$res" ]; then
		echo -e "Failed to update the custom role: '$DNSZoneManagementRoleName'" "\n"
		exit 1
	fi
	echo -e "custom role updated successfully, RoleDefinitionID:" "$DNSZoneRoleDefID" "\n"
	return
  fi

  #create snapcenter DNS zone management custom role at Private zone scope
  DNSZoneRoleDefID=$(az role definition create --role-definition '{
	  "Name": "'"$DNSZoneManagementRoleName"'",
	  "IsCustom": true,
	  "Description": "SnapCenter AKS DNS Zone management role",
	  "Actions": ['"$permissions"'],
	  "NotActions": [],
	  "AssignableScopes": ["'"$dnsZoneScope"'"]
	}' --query 'id' -o tsv)

  if [ -z "$DNSZoneRoleDefID" ]; then
    echo -e "Failed to create the custom role: '$DNSZoneManagementRoleName'" "\n"
    exit 1
  fi

  echo -e "custom role '$DNSZoneManagementRoleName' created, RoleDefinitionID:" "$DNSZoneRoleDefID" "\n"
}


roleAssignments() {
  #sleep for few seconds, because sometimes user msi wont be created, adding sleep for 45 seconds
  echo "adding sleep for 45 seconds, to ensure MSI is already created before role assignment, even after that if role assignment fails then re-execute the script."
  sleep 45

  #Assign custom role to user msi
  managedClusterRoleAssignmentID=$(az role assignment create --assignee "$userMSIPrincipleID" --role "$ManagedClusterRoleName" --resource-group "$ResourceGroup" --query 'id' -o tsv)

  if [ -z "$managedClusterRoleAssignmentID" ]; then
    echo "Failed to assign the role: '$NetworkManagementRoleName' to user managed identity."
    exit 1
  fi

  echo "Successfully assigned the role '$ManagedClusterRoleName' to user managed identity and and the Role AssignmentId is '$managedClusterRoleAssignmentID'"

  #sleep for few seconds, because azure sometimes takes time to reflect the permissions
  echo "adding sleep for 45 seconds, to make sure permissions are reflected"
  sleep 45

  #Assign Network Contributor role to user msi
  networkRoleAssignmentID=$(az role assignment create --assignee "$userMSIPrincipleID" --role "$NetworkManagementRoleName" --scope "$vnetScope" --query 'id' -o tsv)

  if [ -z "$networkRoleAssignmentID" ]; then
    echo "Failed to assign the role: '$NetworkManagementRoleName' to user managed identity."
    exit 1
  fi

  echo "Successfully assigned the role '$NetworkManagementRoleName' to user managed identity and the Role AssignmentId is '$networkRoleAssignmentID'"

  if [ ! -z "$RouteTableRoleDefID" ]; then
  #Assign route table Contributor role to user msi
  routeTableRoleAssignmentID=$(az role assignment create --assignee "$userMSIPrincipleID" --role "$RouteTableRoleDefID" --scope "$routeTableScope" --query 'id' -o tsv)

  if [ -z "$routeTableRoleAssignmentID" ]; then
    echo "Failed to assign the role: '$routTableManagementRoleName' to user managed identity."
    exit 1
  fi

  echo "Successfully assigned the role '$routTableManagementRoleName' to user managed identity and the Role AssignmentId is '$routeTableRoleAssignmentID'"
  fi
  echo $DNSZoneRoleDefID
  if [ ! -z "$DNSZoneRoleDefID" ]; then
  #Assign DNS Zone role to Private DNS Zone
  DNSZoneRoleAssignmentID=$(az role assignment create --assignee "$userMSIPrincipleID" --role "$DNSZoneRoleDefID" --scope "$dnsZoneScope" --query 'id' -o tsv)

  if [ -z "$DNSZoneRoleAssignmentID" ]; then
    echo "Failed to assign the role: '$DNSZoneManagementRoleName' to user managed identity."
    exit 1
  fi

  echo "Successfully assigned the role '$DNSZoneManagementRoleName' to user managed identity and the Role AssignmentId is '$DNSZoneRoleAssignmentID'"
  fi
}

assignUserMSI() {
  #Assign user msi to service connector
  userAssignedIdentities=$(az vm identity assign -g "$ResourceGroup" -n "$ConnectorName" --identities "$userMSIName")

  if [ -z "$userAssignedIdentities" ]; then
    echo "Failed to assign user managed identity to service connector. '$userAssignedIdentities'"
    exit 1
  fi

  bold=$(tput bold)
  normal=$(tput sgr0)

  echo -e "User assigned managed identity ${bold}'$userMSIName'${normal} successfully created and assigned to connector." "\n"
}

#Entrypoint
OPTIND=1
# Resetting OPTIND is necessary if getopts was used previously in the script.
# It is a good idea to make OPTIND local if you process options in a function.

while getopts h:s:g:c: opt; do
  case $opt in
  h)
    show_help
    exit 0
    ;;
  s)
    SubscriptionID=$OPTARG
    ;;
  g)
    ResourceGroup=$OPTARG
    ;;
  c)
    ConnectorName=$OPTARG
    ;;
  *)
    show_help >&2
    exit 1
    ;;
  esac
done
shift "$((OPTIND - 1))" # Discard the options and sentinel --

validate
echo "user MSI creation in progress.."
createUserMSI
echo "cluster admin role creation in progress.."
createManagedClusterRole
echo "network management role creation in progress.."
createNetworkManagementRole
echo "route table management role creation in progress.."
createUDRRole
echo "private DNS Zone creation in progress.."
createPrivateDNSZone
echo "private DNS Zone management role in progress.."
createPrivateDNSRole
echo "role assignments in progress.."
roleAssignments
echo "assigning user MSI in progress.."
assignUserMSI