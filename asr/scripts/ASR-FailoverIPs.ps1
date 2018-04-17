<# 
    .SYNOPSIS

        Migrate IP addresses of replicated VMs to Azure.

    .DESCRIPTION 
        
        This script will migrate IP addresses of replicated VMs to Azure using Neon. It will
        first invoke Neon APIs to migrate the IP addresses and then invoke ASR APIs to 
        to set the static IP addresses for the replicated VMs. Once this script has finished,
        you can failover the VMs to Azure while retaining their IP addresses.

    .PARAMETER NeonCredential
        Neon credential (access key ID and secret)

    .PARAMETER ResourceGroup
        Name of the resource group containing the ASR vault.

    .PARAMETER Vault
        Name of the vault

    .PARAMETER RecoveryPlanName
        Name of the recovery plan. If supplied, the IP addresses of all protected VMs in the 
        recovery plan are migrated.
        N.B. Either the RecoveryPlanName or VmName must be supplied.

    .PARAMETER VmName
        Name of the VM. If supplied, the IP addresses of the VM are migrated.
        N.B. Either the RecoveryPlanName or VmName must be supplied.
#>

Param(
    [Parameter(Mandatory = $true)] [pscredential]$NeonCredential,
    [Parameter(Mandatory = $true)] [string]$ResourceGroup,
    [Parameter(Mandatory = $true)] [string]$Vault,
    [Parameter(Mandatory = $false)] [string]$RecoveryPlanName,
    [Parameter(Mandatory = $false)] [string]$VmName
)

function WaitForActivities {
    Param(
        [Parameter(Mandatory = $true)] [pscredential]$NeonCredential,
        [Parameter(Mandatory = $true)] [Object]$Activities
    )

    $done = $false
    while (!$done) {
        # Check whether any activity is still pending and if so, sleep and retry.
        $done = $true
        foreach ($a in $Activities) {
            if (!$a.activity_id) {
                continue
            }

            $activity = .\NeonClient.ps1 -Credential $NeonCredential -Method GET -Path "activities/$($a.activity_id)"
            if ($activity.state -eq "Pending") {
                $done = $false
                break
            }
        }

        if (!$done) {
            Start-Sleep -s 5
        }

        Write-Output "Waiting for endpoint migration to complete..."
    }
}

function MigrateIPs {
    Param(
        [Parameter(Mandatory = $true)] [pscredential]$NeonCredential,
        [Parameter(Mandatory = $true)] [string]$ResourceGroup,
        [Parameter(Mandatory = $true)] [string]$Vault,
        [Parameter(Mandatory = $false)] [string]$RecoveryPlanName,
        [Parameter(Mandatory = $false)] [string]$VmName
    )

    # If recovery plan is provided get the list of replicated items for the recovery plan.
    $subscriptionId = ((Get-AzureRmContext).Subscription).SubscriptionId
    $vmMap = @{}
    if ($RecoveryPlanName) {
        $recoveryPlan = Get-AzureRmResource -ResourceId "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.RecoveryServices/vaults/$Vault/replicationRecoveryPlans/$RecoveryPlanName" -ApiVersion "2018-01-10"
        foreach ($group in $recoveryPlan.Properties.Groups) {
            if ($group.groupType -eq "Boot") {
                foreach ($item in $group.replicationProtectedItems) {
                    $vmMap[$item.Id] = $true
                }
            }
        }
    }
    
    # Get the list of VMs that are being migrated.
    "Getting replicated items..." 
    $subscriptionId = ((Get-AzureRmContext).Subscription).SubscriptionId
    $items = Get-AzureRmResource -ResourceId "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.RecoveryServices/vaults/$Vault/replicationProtectedItems" -ApiVersion "2018-01-10"    
    $vms = @()
    foreach ($item in $items) {
        if ($vmMap[$item.ResourceId] -or $item.Properties.FriendlyName -eq $VmName) {
            # Check if the VM is in the correct state and if so, add it to the list of VMs to be migrated.
            if (($item.Properties.ProtectionState -eq "Protected") -and
                ($item.Properties.providerSpecificDetails.recoveryAzureVMName)) {
                $vms += $item
            }
        }
    }

    if ($vms.Length -eq 0) {
        Write-Output "No suitable VMs found."
        return
    }

    # Get the list of cloud gateways.
    Write-Output "Getting list of cloud gateways..."
    $cgwMap = @{}
    $cgws = .\NeonClient.ps1 -Credential $NeonCredential -Method GET -Path cgws
    foreach ($cgw in $cgws) {
        $cgwMap[$cgw.subnet_id] = $cgw
    }

    # Get the list of networks.
    Write-Output "Getting list of networks..."
    $networkMap = @{}
    $networks = .\NeonClient.ps1 -Credential $NeonCredential -Method GET -Path networks
    foreach ($network in $networks) {
        $networkMap[$network.network_name] = $network
    }

    # Get the list of endpoints.
    Write-Output "Getting list of endpoints..."
    $endpoints = .\NeonClient.ps1 -Credential $NeonCredential -Method GET -Path nics
    $updates = @{}
    foreach ($vm in $vms) {
        # Prepare the list of endpoint-updates for the VM NICs.
        $ip = $vm.Properties.providerSpecificDetails.ipAddress
        $nics = $vm.Properties.providerSpecificDetails.vmNics
        foreach ($nic in $nics) {
            # Get all discovered endpoints corresponding to this NIC.
            $subnet = $nic.recoveryVMSubnetName
            $nicEndpoints = @()
            foreach ($endpoint in $endpoints) {
                if (($endpoint.mac -eq $nic.nicId) -and ($endpoint.network_name -eq $subnet)) {
                    $nicEndpoints += @{ip = $endpoint.ip; mac = $endpoint.mac}    
                }
            }
   
            # Special case for NIC0. If NIC0 is not discovered yet, we can still perform
            # the migration if the IP address is known.
            if (($nicEndpoints.Length -eq 0) -and ($nics.IndexOf($nic) -eq 0) -and $ip) {
                $nicEndpoints += @{ip = $ip; mac = $nic.nicId}
            }
            
            # Lookup network and cloud gateway based on subnet.
            if (!$networkMap.ContainsKey($subnet) -or !$cgwMap.ContainsKey($subnet)) {
                throw "VM '$($vm.Properties.providerSpecificDetails.recoveryAzureVMName)' NIC '$($nic.NicId)' has been assigned a subnet '$subnet' that does not exist in Neon. Please check that the VM's vnet and subnet has been assigned correctly."
            }

            # ASR API only allows setting one IP address for a NIC.
            if ($nicEndpoints.Length -gt 0) {
                $nic.replicaNicStaticIPAddress = $nicEndpoints[0].ip
            }

            # If there is already an update object for this subnet, add the endpoints to the 
            # update object. Otherwise create a new update object.
            $network = $networkMap[$subnet]
            $cgw = $cgwMap[$subnet]
            if (!$updates.ContainsKey($network.network_id)) {
                $update = @{endpoints = @()}
                $update.cgw_id = $cgw.cgw_id
                $update.sync = $true
                $update.age = 0
                $updates[$network.network_id] = $update
            } else {
                $update = $updates[$network.network_id]
            }

            $update.endpoints += $nicEndpoints   
        }
    }

    # Call Neon API to migrate the endpoints.
    Write-Output "Migrating endpoints..."
    $activities = @()
    foreach ($update in $updates.GetEnumerator()) {
        $cmd = @{command_type = "network_update_endpoints"; endpoints = $update.Value}
        $networkId = $update.Key
        $activities += .\NeonClient.ps1 -Credential $NeonCredential -Method POST -Path "networks/$networkId/actions" -Body $cmd
    }

    # Wait for all endpoints to be migrated.
    Write-Output "Waiting for endpoint migration to complete..."
    WaitForActivities -NeonCredential $NeonCredential -Activities $activities

    # Set static IPs for replicated items.
    Write-Output "Setting static IP for VMs..."
    foreach ($vm in $vms) {
        $vmNics = @()
        foreach ($nic in $vm.Properties.providerSpecificDetails.vmNics) {
            Write-Output "Setting VM $($vm.Properties.providerSpecificDetails.recoveryAzureVMName) NIC $($nic.NicId) IP $($nic.replicaNicStaticIPAddress)"
            $vmNics += @{   
                nicId = $nic.nicId
                recoveryVMSubnetName = $nic.recoveryVMSubnetName
                replicaNicStaticIPAddress = $nic.replicaNicStaticIPAddress
                selectionType = $nic.selectionType
            }
        }

        if ($vmNics.Length -gt 0) {        
            $properties = @{
                vmNics = $vmNics
                selectedRecoveryAzureNetworkId = $vm.Properties.providerSpecificDetails.selectedRecoveryAzureNetworkId
                providerSpecificDetails = @{
                    instanceType = $vm.Properties.providerSpecificDetails.instanceType
                    recoveryAzureV2ResourceGroupId = $vm.Properties.providerSpecificDetails.recoveryAzureResourceGroupId
                }
            }
            
            Set-AzureRmResource -UsePatchSemantics -Force -ResourceId $vm.ResourceId -ApiVersion "2018-01-10" -Properties $properties
        }
    }
}

$ErrorActionPreference = "Stop"

MigrateIPs -NeonCredential $NeonCredential -ResourceGroup $ResourceGroup -Vault $Vault -RecoveryPlanName $RecoveryPlanName -VmName $VmName
