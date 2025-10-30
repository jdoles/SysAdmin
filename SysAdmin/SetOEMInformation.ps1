<#
    SetOEMInformation.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-05-21
    Repository: https://github.com/jdoles/SysAdmin
#>
<#
    .SYNOPSIS
        This script sets OEM information in the registry.
    .DESCRIPTION
        This script sets OEM information in the registry to the values specified in the script.  The OEM information includes Manufacturer, Model, SupportURL, SupportHours, SupportPhone, and Logo.
        This information is used by Windows to display OEM branding and support information.
        https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-oeminformation
    .EXAMPLE
        SetOEMInformation.ps1
    .NOTES
        This script requires PowerShell 5 or higher and administrative privileges.
    .PARAMETER None
        No parameters are required for this script.
#>

# Function to log messages with a timestamp
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level]: $Message"
}

function Get-WMIInfo {
    param (
        [string]$ClassName,
        [string]$PropertyName
    )
    $wmiObject = Get-WmiObject -Class $ClassName -ErrorAction SilentlyContinue
    if ($wmiObject) {
        return $wmiObject.$PropertyName
    } else {
        Write-Log -Message "WMI class $ClassName not found." -Level "ERROR"
        return $null
    }
}

# Check if the script is running with administrative privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log -Message "This script requires administrative privileges. Please run as Administrator." -Level "ERROR"
    exit 1
}

# Root key for OEM information
$rootKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"

# Get the model from WMI
$model = Get-WMIInfo -ClassName "Win32_ComputerSystem" -PropertyName "Model"

# Get the manufacturer from WMI
$manufacturer = Get-WMIInfo -ClassName "Win32_ComputerSystem" -PropertyName "Manufacturer"

# List of subkeys to check and set
$subKeys = @{
    # Only set the Manufacturer if it is not HP, Hewlett-Packard, Microsoft, or Lenovo. Adjust as needed or comment out.
    #Manufacturer = if ($manufacturer -notlike "HP*" -and $manufacturer -notlike "Lenovo*" -and $manufacturer -notlike "Hewlett-Packard*" -and $manufacturer -notlike "Microsoft*") { "Manufacturer" } else { $manufacturer }
    # Set the Manufacturer to the WMI value if it is present.
    #Manufacturer = if ($manufacturer) { $manufacturer } else { "Unknown Manufacturer" } 
    # Custom Manufacturer name. This is the name that will be displayed in the UI.
    Manufacturer = "" # Depcrecated, but still appears in the UI
    Model = if ($model) { $model } else { "Unknown Model" } # Depcrecated
    SupportAppURL = "" # URI for the OEM support app. Required, unless SupportURL is present, in which case it is optional. If both are supplied, SupportAppURL is used.
    SupportURL = "https://example.com" # Specifies the URL of the support website for an OEM. Required, unless SupportAppURL is present
    SupportHours = "SupportHours" # Depcrecated, but still appears in the UI
    SupportPhone = "SupportPhone" # Depcrecated, but still appears in the UI
    SupportProvider = "SupportProvider" # Name of OEM support app or website.
    Logo = "" # Deprecated. Does not show in Get Help app.
}

# Iterate through each subkey
$subKeys.Keys | ForEach-Object {
    $subKey = $_
    $value = Get-ItemProperty -Path $rootKey -Name $subKey -ErrorAction SilentlyContinue
    if ($value) {
        Write-Log -Message "Found $($subKey): $($value.$subKey)"
    } else {
        Write-Log -Message "$subKey not found."
    }

    Write-Log -Message "Setting $($subKey) to $($subKeys[$subKey])"
    Set-ItemProperty -Path $rootKey -Name $subKey -Value $subKeys[$subKey] -ErrorAction SilentlyContinue
}