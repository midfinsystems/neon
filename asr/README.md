# Runbooks for IP migration using Neon and Azure Site Recovery

[![Deploy to Azure](http://azuredeploy.net/deploybutton.png)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmidfinsystems%2Fneon%2Fmaster%2Fasr%2F%2Fazuredeploy.json)

This Resource Manager Template will deploy Automation Runbooks for IP migration using Neon and
Azure Site Recovery.

### Pre-reqs

All the runbooks requires an **Azure RunAs Account** in the automation account. This can be created manually in the portal post deployment. 

### Automation Runbooks for Azure Site Recovery 

##### ASR-FailoverRunbook

This runbook migrates the IP addresses of a specific VM or all VMs in a recovery plan using Neon
and Azure Site Recovery.

##### ASR-FailoverIPs

This is a helper script called by ASR-FailoverRunbook to migrate the IP addresses of replicated
VMs to Azure using Neon and to set the VMs static IP address in ASR.

##### NeonClient

This is a helper script called by ASR-FailoverIPs to make REST API calls to Neon. 
