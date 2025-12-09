<#
    CreateDNSZones.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-12-09
    Repository: https://github.com/jdoles/SysAdmin
#>
<#
    .SYNOPSIS
        Creates DNS zones in Azure DNS for the specified zones if they do not already exist.
    .DESCRIPTION
        This script connects to Azure using the provided subscription name and creates DNS zones in the specified resource group for each zone listed in the input array. If a zone already exists, it skips creation and logs a warning.
    .PARAMETER Zones
        An array of DNS zone names to be created. Each zone will be checked for existence before creation.
    .PARAMETER subscriptionName
        The name of the Azure subscription to connect to.
    .PARAMETER ResourceGroupName
        The name of the resource group where the DNS zones will be created.
    .EXAMPLES
        .\CreateDNSZones.ps1 -Zones @("example.com", "contoso.com") -subscriptionName "MyAzureSubscription" -ResourceGroupName "MyDNSResourceGroup"
        This command creates DNS zones for "example.com" and "contoso.com" in the specified subscription and resource group.
#>

param (
    [Parameter(Mandatory=$true)]
    [string[]]$Zones,
    [Parameter(Mandatory=$true)]
    [string]$subscriptionName,
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName
)

# List of required modules
$requiredModules = @(
    "Az.Accounts",
    "Az.Dns"
)

$results = @()

# Function to log messages with a timestamp
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "INFO" { $color = "Green" }
        "WARN" { $color = "Yellow" }
        "ERROR" { $color = "Red" }
        default { $color = "White" }
    }
    Write-Host "[$timestamp] [$Level]: $Message" -ForegroundColor $color
}

# Import required modules, installing them if missing
function Import-ModuleIfMissing {
    param (
        [Parameter(Mandatory=$true)]
        [string[]]$Modules
    )
    try {
        foreach ($ModuleName in $Modules) {
            if (!(Get-Module -ListAvailable -Name $ModuleName)) {
                Write-Log -Message "Installing module: $ModuleName" -Level "INFO"
                Install-Module -Name $ModuleName -Force -AllowClobber -Scope CurrentUser
                Write-Log -Message "Importing module: $ModuleName" -Level "INFO"
                Import-Module -Name $ModuleName -Force
            } else {
                Write-Log -Message "Module $ModuleName is already installed." -Level "INFO"
                Write-Log -Message "Importing module: $ModuleName" -Level "INFO"
                Import-Module -Name $ModuleName -Force
            }
        }
    } catch {
        Write-Log -Message "Failed to load required module: $ModuleName" -Level "ERROR"
        exit 1
    }
}

# Main script logic
try {
    Import-ModuleIfMissing -Modules $requiredModules
    Connect-AzAccount -Subscription $SubscriptionName | Out-Null
    # Probably not needed with Connect-AzAccount above, but just in case
    Get-AzContext -Name $SubscriptionName | Select-AzContext

    foreach ($zone in $Zones) {
        Write-Log "Checking for DNS zone $zone in resource group $ResourceGroupName" "INFO"
        # Check to ensure the zone does not already exist
        $zoneCheck = Get-AzDnsZone -Name $zone -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $zoneCheck) {
            Write-Log "DNS zone $zone does not exist. Creating..." "INFO"
            $zoneNew = New-AzDnsZone -Name $zone -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
            if ($zoneNew) {
                Write-Log "Successfully created DNS zone: $($zoneNew.Name)" "INFO"
                $nsRecordSet = Get-AzDnsRecordSet -ZoneName $zoneNew.Name -ResourceGroupName $ResourceGroupName -RecordType NS -Name "@" -ErrorAction SilentlyContinue
                if ($nsRecordSet) {
                    $nameServers = $nsRecordSet.Records.Nsdname -join "; "
                } else {
                    $nameServers = "No NS records found."
                }

                $results += [PSCustomObject]@{
                    Status      = "Created"
                    ZoneName     = $zoneNew.Name
                    NameServers  = $nameServers
                }
            } else {
                Write-Log "Failed to create DNS zone: $zone" "ERROR"
            }
        } else {
            Write-Log "DNS zone $zone already exists. Skipping." "WARN"
            $results += [PSCustomObject]@{
                Status      = "Exists"
                ZoneName     = $zoneCheck.Name
                NameServers  = "N/A"
            }
        }
    }

    # Output results
    Write-Log "DNS Zone Creation Results:" "INFO"
    $results | Format-Table -AutoSize

    Disconnect-AzAccount | Out-Null
} catch {
    Write-Log -Message "Error occurred: $_" -Level "ERROR"
}