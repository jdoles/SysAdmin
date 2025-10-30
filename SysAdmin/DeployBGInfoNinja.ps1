<#
    DeployBGInfoNinja.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-09-24
    Repository: https://github.com/jdoles/SysAdmin
#>
<#
    .SYNOPSIS
        This script deploys BGInfo to the target PC using files staged by Ninja RMM.
    .DESCRIPTION
        This script searches for BGInfo files in the Ninja RMM staging directory, copies them to C:\BGInfo on the target PC, and runs BGInfo with a specified configuration file.
        This is intended to be run as a post-deployment script in Ninja RMM.
    .EXAMPLE
        DeployBGInfoNinja.ps1
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

function New-Shortcut {
    [CmdletBinding()]
    param(
        [Parameter()]
        [String]$Arguments,
        [Parameter()]
        [String]$IconPath,
        [Parameter(ValueFromPipeline = $True)]
        [String]$Path,
        [Parameter()]
        [String]$Target,
        [Parameter()]
        [String]$WorkingDir
    )
    process {
        Write-Log -Message "Creating Shortcut at $Path"
        $ShellObject = New-Object -ComObject ("WScript.Shell")
        $Shortcut = $ShellObject.CreateShortcut($Path)
        $Shortcut.TargetPath = $Target
        if ($WorkingDir) { $Shortcut.WorkingDirectory = $WorkingDir }
        if ($Arguments) { $ShortCut.Arguments = $Arguments }
        if ($IconPath) { $Shortcut.IconLocation = $IconPath }
        $Shortcut.Save()
        if (!(Test-Path $Path -ErrorAction SilentlyContinue)) {
            Write-Log -Message "Unable to create Shortcut at $Path" -Level "ERROR"
            exit 1
        }
    }
}

function Register-BGInfoStartup {
    param (
        [string]$TargetDir,
        [string]$ConfigFile
    )

    $ExePath = Join-Path -Path $TargetDir -ChildPath "\BGInfo64.exe"
    $Config = Join-Path -Path $TargetDir -ChildPath "\$ConfigFile"

    if (-not $(Test-Path -Path $ExePath -ErrorAction SilentlyContinue)) {
        Write-Log -Message "BGInfo.exe is not found at $ExePath" -Level "ERROR"
        Exit 1
    }

    # Register Startup command for All User
    try {
        $StartupPath = Join-Path -Path $env:ProgramData -ChildPath "Microsoft\Windows\Start Menu\Programs\StartUp\StartupBGInfo.lnk"
        
        if ($(Test-Path -Path $StartupPath -ErrorAction SilentlyContinue)) {
            Remove-Item -Path $StartupPath -ErrorAction SilentlyContinue
        }
        if ($Config -and $(Test-Path -Path $Config -ErrorAction SilentlyContinue)) {
            New-Shortcut -Path $StartupPath -Arguments "/iq `"$Config`" /nolicprompt /timer:0 /silent" -Target $ExePath
        }
        else {
            New-Shortcut -Path $StartupPath -Arguments "/nolicprompt /timer:0 /silent" -Target $ExePath
        }

        Write-Log -Message "Created Startup: $StartupPath"
    }
    catch {
        Write-Log -Message "Unable to create shortcut for BGInfo.exe" -Level "ERROR"
        Exit 1
    }
}

$stagingDir = "C:\ProgramData\NinjaRMMAgent" # Ninja RMM staging directory
$targetDir = "$env:WinDir\SysInternals" # Target directory on the PC
$configFileName = "bgDisplay.bgi" # BGInfo configuration file name
$files = @(
    "BGInfo64.exe", 
    $configFileName
)
$filesCopied = $true # Flag to track if all files were copied successfully

if (-not (Test-Path -Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force
    (Get-Item $targetDir).Attributes += 'Hidden'
    Write-Log -Message "Created hidden directory $targetDir on the target PC."
}

foreach ($file in $files) {
    # Search recursively in the NinjaRMM staging directory for each file
    $stagingFilePath = Get-ChildItem -Path $stagingDir -Recurse -Filter $file -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($stagingFilePath) {
        # Copy the file to C:\BGInfo on the target PC
        Copy-Item -Path $stagingFilePath.FullName -Destination "$targetDir\$file" -Force
        Write-Log -Message "$file found and copied to $targetDir on the target PC."
    } else {
        Write-Log -Message "File $file not found in the NinjaRMM staging directory. Exiting." -Level "ERROR"
        $filesCopied = $false
    }
}

if ($filesCopied) {
    # All files were copied successfully, proceed to run BGInfo
    # Register BGInfo to run at startup
    Register-BGInfoStartup -TargetDir $targetDir -ConfigFile $configFileName
    
} else {
    Write-Log -Message "Not all files were copied successfully. BGInfo will not be executed." -Level "ERROR"
    Exit 1
}