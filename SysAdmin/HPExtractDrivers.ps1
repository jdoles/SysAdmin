<#
    HPExtractDrivers.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-09-08
    Repository: https://github.com/jdoles/SysAdmin
#>
<#
    .SYNOPSIS
    This script extracts drivers from HP driver packages.
    .DESCRIPTION
    The script scans a specified directory for HP driver packages and extracts the contents to a designated folder.
    .EXAMPLE
    PS C:\> .\HPExtractDrivers.ps1 -BasePath 'C:\drivers\HP Elite Mini 800 G9\'
    This command extracts drivers from the specified HP driver package directory.
    .PARAMETER BasePath
    The base path to the HP driver package directory.
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$BasePath
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

if (-not (Test-Path -Path $BasePath)) {
    Write-Log -Message "The specified path does not exist: $BasePath" -Level "ERROR"
    exit
} else {
    if (-not ($BasePath.EndsWith("\"))) {
        $BasePath += "\"
    }
    Write-Log -Message "Using specified path: $BasePath"
    Get-ChildItem -Path $BasePath -File | ForEach-Object {
        $extracted = $BasePath + "extracted"
        if (-not (Test-Path -Path $extracted)) {
            Write-Log -Message "Creating folder for extracted files" -Level "INFO"
            New-Item -Path $extracted -ItemType Directory | Out-Null
        }
        
        $exe = $_.FullName
        $a = '/e /s /f "' + $extracted + '"'
        Write-Log -Message "Extracting $($_.Name) to $extracted" -Level "INFO"
        Start-Process $exe -ArgumentList $a
    }
}