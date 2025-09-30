<#
    CreateSonicwallProfile.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-09-30
    Repository: https://github.com/jdoles/PowerShell
#>
<#
    .SYNOPSIS
    Configures and launches SonicWall NetExtender VPN connection using specified profile.
    .DESCRIPTION
    This script stops any running instances of NetExtender, configures a VPN connection profile using
    the provided server address, username, and domain, and then launches the NetExtender application.
    .PARAMETER VPNServer
    The address of the VPN server (e.g., "vpn.example.com:443").
    .PARAMETER Domain
    The domain for the VPN connection (e.g., "MYDOMAIN.local").
    .PARAMETER Username
    The username for the VPN connection. Defaults to the current user's username.
    .PARAMETER ProfileName
    The name of the VPN profile to create or update. Defaults to "VPN".
    .PARAMETER NxCliPath
    The file path to the NetExtender CLI executable. Defaults to "C:\Program Files\SonicWall\SSL-VPN\NetExtender\NxCli.exe".
    .PARAMETER NxPath
    The file path to the NetExtender GUI executable. Defaults to "C:\Program Files\SonicWall\SSL-VPN\NetExtender\NetExtender.exe".
    .PARAMETER StartClient
    A switch to indicate whether to launch the NetExtender GUI after configuring the profile.
    .EXAMPLE
    .\SetSonicwallProfileHW.ps1 -VPNServer "vpn.example.com:443" -Domain "MYDOMAIN.local" -Username "jdoe" -StartClient
    Configures the VPN profile for user "jdoe" and launches the NetExtender client.
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$VPNServer,
    [Parameter(Mandatory=$true)]
    [string]$Domain,
    [Parameter(Mandatory=$false)]
    [string]$Username = $env:USERNAME,
    [Parameter(Mandatory=$false)]
    [string]$ProfileName = "VPN",
    [Parameter(Mandatory=$false)]
    [string]$NxCliPath = "C:\Program Files\SonicWall\SSL-VPN\NetExtender\NxCli.exe",
    [Parameter(Mandatory=$false)]
    [string]$NxPath = "C:\Program Files\SonicWall\SSL-VPN\NetExtender\NetExtender.exe",
    [Parameter(Mandatory=$false)]
    [switch]$StartClient
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

Write-Log -Message "Stopping any running instances of NetExtender"
Get-Process -Name "NetExtender" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Log -Message "Configuring VPN connection profile"
Write-Log -Message "VPN Server: $VPNServer"
Write-Log -Message "Domain: $Domain"
Write-Log -Message "Username: $Username"
Write-Log -Message "Profile Name: $ProfileName"

if (Test-Path -Path $NxCliPath) {
    & $NxCliPath connection add HW -s $VPNServer -u $Username -d $Domain -v auto
    Write-Log -Message "Profile '$ProfileName' configured successfully"
    if ($StartClient) {
        Write-Log -Message "Starting NetExtender client"
        if (Test-Path -Path $NxPath) {
            Start-Process -FilePath $NxPath
        } else {
            Write-Error "NetExtender not found at $NxPath"
        }
    } else {
        Write-Log -Message "StartClient switch not set. Skipping launching NetExtender client."
    }
} else {
    Write-Error "NetExtender CLI not found at $NxCliPath"
}