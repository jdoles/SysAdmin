<#
    StopAllBrowsers.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-10-23
    Repository: https://github.com/jdoles/PowerShell
#>
<#
    .SYNOPSIS
        Stops all common web browsers if they are running.
    .DESCRIPTION
        This script checks for running instances of common web browsers and stops them if found.
    .EXAMPLE
        .\StopAllBrowsers.ps1
        Stops all running web browsers.
    .NOTES
        Ensure you run this script with appropriate permissions to stop processes.
#>

# List of common web browsers to check and stop
$browsers = @(
    "chrome",
    "firefox",
    "msedge",
    "opera",
    "brave",
    "vivaldi",
    "iexplore"
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

# Function to stop a process if it is running
function Stop-ProcessIfRunning {
    param (
        [string]$ProcessName
    )
    try {
        $process = Get-Process -Name $ProcessName -ErrorAction Stop
        Write-Log "$ProcessName is running." "INFO"
        try {
            Stop-Process -InputObject $process -Force -ErrorAction Stop
            Write-Log "$ProcessName has been stopped." "INFO"
        }
        catch {
            Write-Log "Failed to stop ${ProcessName}: $_" "ERROR"
        }        
    } catch {
        Write-Log "$ProcessName is not running." "WARN"
    }
}

# Iterate through each browser and stop it if running
foreach ($browser in $browsers) {
    Stop-ProcessIfRunning -ProcessName $browser
}