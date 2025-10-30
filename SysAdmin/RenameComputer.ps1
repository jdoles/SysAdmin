<#
    RenameComputer.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-10-07
    Repository: https://github.com/jdoles/SysAdmin
#>
<#
    .SYNOPSIS
        This script renames the computer and optionally reboots it.
    .DESCRIPTION
        This script renames the computer to the specified new name and reboots it unless the NoReboot flag is set.
    .EXAMPLE
        RenameComputer.ps1 -NewName "NewPCName" -NoReboot
    .NOTES
        This script requires PowerShell 5 or higher and administrative privileges.
    .PARAMETER NewName
        The new name for the computer. This parameter is mandatory.
    .PARAMETER NoReboot
        If specified, the computer will not reboot after renaming.
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$NewName,
    [Parameter(Mandatory=$false)]
    [switch]$NoReboot
)

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

# Function to rename the computer
function Rename-ComputerAndHandleReboot {
    param (
        [string]$NewName,
        [switch]$NoReboot
    )

    try {
        # Rename the computer
        Rename-Computer -NewName $NewName -Force -ErrorAction Stop
        Write-Log -Message "Computer renamed to '$NewName' successfully."

        if (-not $NoReboot) {
            Write-Log -Message "Rebooting the computer to apply changes..."
            Restart-Computer -Force
        } else {
            Write-Log -Message "Reboot skipped as per the NoReboot flag."
        }
    } catch {
        Write-Log -Message "Failed to rename the computer: $_" -Level "ERROR"
    }
}

# Call the function with provided parameters
if ($NewName) {
    Write-Log -Message "Starting the renaming process..."
    Rename-ComputerAndHandleReboot -NewName $NewName -NoReboot:$NoReboot
} else {
    Write-Log -Message "NewName parameter is required." -Level "ERROR"
    exit 1
}
