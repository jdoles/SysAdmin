#Requires -Version 5.1
<#
.SYNOPSIS
    This script gathers the list of installed Chrome and Microsoft Edge extensions for the current user and displays their names, versions, and extension IDs.
.DESCRIPTION
    This script gathers the list of installed Chrome and Microsoft Edge extensions for the current user and displays their names, versions, browser, and extension IDs. It reads the manifest.json file of each extension to retrieve this information. Extensions that localize their name store it as a placeholder like "__MSG_appName__" in manifest.json; in that case the script looks up the real name in the extension's _locales/<locale>/messages.json file. If a manifest can't be parsed at all, it falls back to "Unknown".
.EXAMPLE
    Get-BrowserExtensions
.NOTES
    Author: Justin Doles
    Date: 2026-09-22
    Requires: PowerShell 5 or higher
#>

function Resolve-LocalizedExtensionName {
    param(
        [string]$Name,
        [string]$DefaultLocale,
        [string]$VersionFolderPath
    )

    if ($Name -notmatch '^__MSG_(.+)__$') {
        return $Name
    }
    $Key = $Matches[1]

    $LocalesPath = Join-Path $VersionFolderPath "_locales"
    if (-not (Test-Path $LocalesPath)) {
        return $Name
    }

    $AvailableLocales = Get-ChildItem -Path $LocalesPath -Directory | Select-Object -ExpandProperty Name
    $LocaleCandidates = @($DefaultLocale, 'en', 'en_US', 'en_GB') + $AvailableLocales |
        Where-Object { $_ } | Select-Object -Unique

    foreach ($Locale in $LocaleCandidates) {
        $MessagesPath = Join-Path $LocalesPath (Join-Path $Locale "messages.json")
        if (-not (Test-Path $MessagesPath)) { continue }

        try {
            $Messages = Get-Content -Raw -Path $MessagesPath | ConvertFrom-Json
            $Entry = $Messages.PSObject.Properties | Where-Object { $_.Name -ieq $Key } | Select-Object -First 1
            if ($Entry -and $Entry.Value.message) {
                return $Entry.Value.message
            }
        } catch {
            continue
        }
    }

    # Key wasn't found in any available locale; return the raw placeholder so it's still visible.
    return $Name
}

$Browsers = @(
    [PSCustomObject]@{ Name = "Chrome"; ExtensionPath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions" }
    [PSCustomObject]@{ Name = "Edge";   ExtensionPath = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Extensions" }
)

$Results = foreach ($Browser in $Browsers) {
    if (-not (Test-Path $Browser.ExtensionPath)) {
        Write-Warning "$($Browser.Name) extension path not found for the current user."
        continue
    }

    Get-ChildItem -Path $Browser.ExtensionPath -Directory -Exclude "Temp" | ForEach-Object {
        # Get the latest version folder inside the extension ID folder
        $VersionFolder = Get-ChildItem -Path $_.FullName -Directory |
            Sort-Object { [version]($_.Name -replace '_\d+$') } -Descending -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $ManifestPath = Join-Path $VersionFolder.FullName "manifest.json"

        if (Test-Path $ManifestPath) {
            try {
                $Manifest = Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json
                $ResolvedName = Resolve-LocalizedExtensionName -Name $Manifest.name -DefaultLocale $Manifest.default_locale -VersionFolderPath $VersionFolder.FullName
                [PSCustomObject]@{
                    Browser     = $Browser.Name
                    ExtensionID = $_.Name
                    Name        = $ResolvedName
                    Version     = $Manifest.version
                }
            } catch {
                # Handles cases where manifest.json is missing or malformed
                [PSCustomObject]@{
                    Browser     = $Browser.Name
                    ExtensionID = $_.Name
                    Name        = "Unknown"
                    Version     = "Unknown"
                }
            }
        }
    }
}

$Results | Format-Table -AutoSize
