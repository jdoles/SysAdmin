<#
    RemoveHPSoftware.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-10-07
    Repository: https://github.com/jdoles/PowerShell
#>
<#
    .SYNOPSIS
        This script uninstalls all non-essential HP software from the system.
    .DESCRIPTION
        This script uninstalls all non-essential HP software from the system using WMI and AppxPackage.
    .EXAMPLE
        RemoveHPSoftware.ps1
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
    switch ($Level) {
        "INFO" { $color = "Green" }
        "WARN" { $color = "Yellow" }
        "ERROR" { $color = "Red" }
        default { $color = "White" }
    }
    Write-Host "[$timestamp] [$Level]: $Message" -ForegroundColor $color
}

function Remove-Software {
    param (
        [Parameter(Mandatory=$true)]
        [System.Management.ManagementObject]$Software
    )

        # Remove the software using Uninstall()
        Write-Log -Message "REMOVE: $($Software.Name)"
        $uninstallCommand = $Software.Uninstall()
        if ($uninstallCommand.ReturnValue -eq 0) {
            Write-Log -Message "Successfully uninstalled: $($Software.Name)"
            $script:appsRemoved++
        } else {
            Write-Log -Message "Failed to uninstall: $($Software.Name)" -Level "ERROR"
        }
}

function Remove-Apps {
    param (
        [string]$AppName,
        [switch]$RemoveFromImage
    )

    # Get the app information using Get-AppxPackage
    $appInfo = Get-AppxPackage -AllUsers | Where-Object {$_.name -like "*$AppName*"}
    if ($appInfo) {
        if ($appInfo.Count -gt 1) {
            Write-Log "Multiple instances of $($appInfo.Name) found. Removing all instances."
            foreach ($instance in $appInfo) {
                if ($instance.NonRemovable -eq $true) {
                    Write-Log -Message "Cannot remove: $($instance.Name) (Non-removable)" -Level "WARN"
                } else {
                    # Remove the app using Remove-AppxPackage
                    Write-Log -Message "REMOVE: $($instance.Name)"
                    $instance | Remove-AppxPackage -AllUsers
                    $script:appsRemoved++
                }
            }
        } else {
            Write-Log -Message "REMOVE: $($appInfo.Name)"
            # Remove the app using Remove-AppxPackage
            $appInfo | Remove-AppxPackage -AllUsers
            $script:appsRemoved++
        }
    } else {
        Write-Log -Message "$appName not found."
    }

    # If the RemoveFromImage switch is specified, remove the app from the system image
    if ($RemoveFromImage) {
        $appImage = Get-AppxProvisionedPackage -Online | Where-Object {$_.DisplayName -like "*$AppName*"}
        if ($appImage) {
            # Remove the app from the image using Remove-AppxProvisionedPackage
            Write-Log -Message "REMOVE: $AppName from image..."
            $appImage | Remove-AppxProvisionedPackage -Online
            $script:appsRemoved++
        } else {
            Write-Log -Message "$AppName not found in image."
        }
    }
}

# List of HP software to uninstall
# This list should contain the names of the HP software you want to uninstall
$software = @(
    "HP Connection Optimizer",
    "HP Customer Experience Enhancements",
    "HP Documentation",
    "HP Easy Clean",
    "HP Dropbox Plugin",
    "HP EmailSMTP Plugin",
    "HP FTP Plugin",
    "HP Games",
    "HP Google Drive Plugin",
    "HP Notifications",
    "HP Odometer",
    "HP OneDrive Plugin",
    "HP Setup",
    "HP SharePoint Plugin",
    "HP SoftPaq Download Manager",
    "HP Software Setup",
    "HP Support Assistant",
    "HP Support Information",
    "HP Sure Click", # HP's application isolation software
    "HP Sure Connect", # HP's network driver recovery software
    "HP Sure Run", # HP's application isolation software
    "HP Sure Run Module", # HP's application isolation software
    "HP System Default Settings",
    "HP Velocity", # HP's network optimization software
    "HP Wallpaper",
    "HP Welcome",
    "HP Wolf Security",
    "HP Wolf Security - Console"
)

# List of UWP apps to remove
$packages = @(
    ".HPDesktopSupportUtilities",
    ".HPEasyClean",
    ".HPSystemInformation",
    ".HPPCHardwareDiagnosticsWindows",
    ".HPJumpStart",
    ".HPPrivacySettings",
    ".HPQuickDrop",
    ".HPSureShieldAI",
    ".HPWorkWise", # HP WorkWise
    ".myHP"   
)

# Counter for the number of apps found
$appsRemoved = 0

# Get the list of installed HP software using WMI
Write-Log -Message "Searching for installed HP software..."
$softwareList = Get-WmiObject -Class  Win32_Product -Filter "Name like 'HP%'" 

if ($softwareList.Count -eq 0) {
    Write-Log -Message "No HP software installations found."
} else {
    Write-Log -Message "Found $($softwareList.Count) HP software installations."
    # Loop through each unwanted software and remove it if found
    $softwareList | ForEach-Object {
        if ($_.Name -in $software) {
            Remove-Software -Software $_
        }
    }
}

# Loop through each unwanted app and remove it if found
$packages | ForEach-Object {
    Remove-Apps -AppName $_ -RemoveFromImage
}

# Check if any apps were removed
if ($appsRemoved -eq 0) {
    Write-Log -Message "No unwanted apps found."
} else {
    Write-Log -Message "$appsRemoved unwanted apps removed."
}