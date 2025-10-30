<#
    RemoveHPWolf.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-05-16
    Repository: https://github.com/jdoles/SysAdmin
#>
<#
    .SYNOPSIS
        This script uninstalls all HP Wolf software from the system.
    .DESCRIPTION
        This script uninstalls all HP Wolf software from the system using WMI. It checks for installed software with names starting with "HP Wolf" and attempts to uninstall them.
    .EXAMPLE
        RemoveHPWolf.ps1
    .NOTES
        This script requires PowerShell 5 or higher and administrative privileges.
    .PARAMETER None
        No parameters are required for this script.
#>

# Find all installed HP Wolf software
$software = Get-WmiObject -Class  Win32_Product -Filter "Name like 'HP Wolf%'"
# This used to determine if the uninstall was successful.  It will be 0 if successful.
$returnValue = 0

# Check if any HP Wolf software is installed
if ($software.Count -gt 0) {
    # Loop through each installed HP Wolf software and uninstall it
    $software | ForEach-Object {
        Write-Host "Uninstalling: $($_.Name)"
        $uninstallCommand = $_.Uninstall()
        if ($uninstallCommand.ReturnValue -eq 0) {
            Write-Host "Successfully uninstalled: $($_.Name)"
        } else {
            Write-Host "Failed to uninstall: $($_.Name)"
            $returnValue++
        }
    }
    # Check if all uninstalls were successful
    if ($returnValue -eq 0) {
        Write-Host "All HP Wolf software uninstalled successfully"
        exit $returnValue
    } else {
        Write-Host "HP Wolf software failed to uninstall"
        exit $returnValue
    }
} else {
    # If no HP Wolf software is found, exit with a success message
    Write-Host "HP Wolf software not found"
    exit 0
}