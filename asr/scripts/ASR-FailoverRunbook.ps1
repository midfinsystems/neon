<# 
    .SYNOPSIS

        Azure automation runbook for migrating IP addresses of replicated VMs to Azure.

    .DESCRIPTION 
        
        This runbook will migrate IP addresses of replicated VMs to Azure using Neon. It will
        first invoke Neon APIs to migrate the IP addresses and then invoke ASR APIs to 
        to set the static IP addresses for the replicated VMs. Once this script has finished,
        you can failover the VMs to Azure while retaining their IP addresses.

        You must define the following Azure Automation variables:

        a) NeonAccessKeyId - Neon Access Key ID.
        b) NeonAccessSecret - Neon Access Secret.


    .PARAMETER ResourceGroup
        Name of the resource group containing the ASR vault. If not supplied, the automation
        variable "NeonDefaultResourceGroup" is used.

    .PARAMETER Vault
        Name of the vault. If not supplied, the automation variable "NeonDefaultVault" is used.

    .PARAMETER RecoveryPlanName
        Name of the recovery plan. If supplied, the IP addresses of all protected VMs in the 
        recovery plan are migrated. If not supplied, the automation variable 
        "NeonDefaultRecoveryPlanName" is used. N.B. Either RecoveryPlanName or VmName must be 
        specified as either input parameters or automation variables.

    .PARAMETER VmName
        Name of the VM. If supplied, the IP addresses of the VM are migrated. If not supplied, 
        the automation variable "NeonDefaultVmName" is used. N.B. Either RecoveryPlanName or 
        VmName as either input parameters or automation variables.
#>

Param(
    [Parameter(Mandatory = $false)] [string]$ResourceGroup,
    [Parameter(Mandatory = $false)] [string]$Vault,
    [Parameter(Mandatory = $false)] [string]$RecoveryPlanName,
    [Parameter(Mandatory = $false)] [string]$VmName
)

$ErrorActionPreference = "Stop"

# Get run-as account.
Try {
    $conn = Get-AutomationConnection -Name AzureRunAsConnection
    Add-AzureRMAccount -ServicePrincipal -Tenant $conn.TenantID -ApplicationId $conn.ApplicationID -CertificateThumbprint $conn.CertificateThumbprint
} Catch {
    Write-Error -Message "Failed to login to Azure."
}

# Get Neon access key and secret from automation variables.
$neonAccessKeyId = Get-AutomationVariable -Name NeonAccessKeyId
$neonAccessSecret = Get-AutomationVariable -Name NeonAccessSecret

# Get input from  automation variables if not supplied as parameters.
if (!$ResourceGroup) {
    $ResourceGroup = Get-AutomationVariable -Name NeonDefaultResourceGroup
}

if (!$Vault) {
    $Vault = Get-AutomationVariable -Name NeonDefaultVault
}

if (!$RecoveryPlanName) {
    $RecoveryPlanName = Get-AutomationVariable -Name NeonDefaultRecoveryPlanName
}

if (!$VmName) {
    $VmName = Get-AutomationVariable -Name NeonDefaultVmName
}

# Validate required parameters.
if (!$neonAccessKeyId -or !$neonAccessSecret -or !$ResourceGroup -or !$Vault) {
    Write-Error -Message "Missing required parameters."
}

# Validate optional parameters.
if (!$RecoveryPlanName -and !$VmName) {
    Write-Error -Message "Either RecoveryPlanName or VmName must be supplied."
}

# Migrate VM IP addresses
$password = $neonAccessSecret | ConvertTo-SecureString -asPlainText -Force
$neonCredential = New-Object System.Management.Automation.PSCredential($neonAccessKeyId, $password)
.\ASR-FailoverIPs.ps1 -NeonCredential $neonCredential -ResourceGroup $ResourceGroup -Vault $Vault -RecoveryPlanName $RecoveryPlanName -VmName $VmName
