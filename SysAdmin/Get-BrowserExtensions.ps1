#Requires -Version 5.1
<#
.SYNOPSIS
    This script gathers the list of installed Chrome, Microsoft Edge, and Firefox extensions for the current user and displays their names, versions, and extension IDs.
.DESCRIPTION
    This script gathers the list of installed Chrome, Microsoft Edge, and Firefox extensions for the current user and displays their names, versions, profile, browser, and extension IDs.
    For Chrome and Edge, it reads the manifest.json file of each extension to retrieve this information. Extensions that localize their name store it as a placeholder like "__MSG_appName__" in manifest.json; in that case the script looks up the real name in the extension's _locales/<locale>/messages.json file.
    For Firefox, extensions are stored as .xpi packages rather than plain folders, so the script instead reads each profile's extensions.json, which already contains the resolved add-on name, version, and ID. All Firefox profiles found for the current user are scanned.
    If an extension's metadata can't be parsed at all, it falls back to "Unknown".
.EXAMPLE
    Get-BrowserExtensions
.NOTES
    Author: Justin Doles
    Date: 2026-09-22
    Requires: PowerShell 5 or higher
#>

function Resolve-LocalizedExtensionName {
    <#
    .SYNOPSIS
        Resolves a Chromium extension's localized name placeholder to its real display name.
    .DESCRIPTION
        Chromium-based extensions that localize their name store a placeholder like
        "__MSG_appName__" in manifest.json instead of a literal string. This function detects
        that pattern, then looks up the actual name in the extension's
        _locales/<locale>/messages.json file, trying the manifest's default locale first and
        falling back to common English locales and whatever locales are actually present.
        If the name isn't a placeholder, or the key can't be resolved, the input name is
        returned unchanged.
    .PARAMETER Name
        The raw "name" value from the extension's manifest.json.
    .PARAMETER DefaultLocale
        The extension's "default_locale" value from manifest.json, if any.
    .PARAMETER VersionFolderPath
        Full path to the extension's version folder (the folder containing manifest.json and,
        for localized extensions, the _locales subfolder).
    .OUTPUTS
        System.String - the resolved display name, or the original value if it couldn't be resolved.
    #>
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

function Get-ChromiumExtensions {
    <#
    .SYNOPSIS
        Gets installed extensions for a Chromium-based browser (Chrome, Edge, etc.).
    .DESCRIPTION
        Scans the given browser's "Default" profile Extensions folder, reads each extension's
        manifest.json from its latest version folder, and resolves any localized name
        placeholder via Resolve-LocalizedExtensionName. Emits one object per extension with
        Browser, Profile, ExtensionID, Name, and Version. If the browser's extension path
        doesn't exist, warns and returns nothing. If a manifest can't be read or parsed, the
        extension is still emitted with Name and Version set to "Unknown".
    .PARAMETER BrowserName
        Display name of the browser (e.g. "Chrome", "Edge"), used to label output rows.
    .PARAMETER ExtensionPath
        Full path to the browser profile's Extensions folder.
    .OUTPUTS
        PSCustomObject with Browser, Profile, ExtensionID, Name, and Version properties.
    #>
    param(
        [string]$BrowserName,
        [string]$ExtensionPath
    )

    if (-not (Test-Path $ExtensionPath)) {
        Write-Warning "$BrowserName extension path not found for the current user."
        return
    }

    Get-ChildItem -Path $ExtensionPath -Directory -Exclude "Temp" | ForEach-Object {
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
                    Browser     = $BrowserName
                    Profile     = "Default"
                    ExtensionID = $_.Name
                    Name        = $ResolvedName
                    Version     = $Manifest.version
                }
            } catch {
                # Handles cases where manifest.json is missing or malformed
                [PSCustomObject]@{
                    Browser     = $BrowserName
                    Profile     = "Default"
                    ExtensionID = $_.Name
                    Name        = "Unknown"
                    Version     = "Unknown"
                }
            }
        }
    }
}

function Get-FirefoxExtensions {
    <#
    .SYNOPSIS
        Gets installed extensions for all Firefox profiles belonging to the current user.
    .DESCRIPTION
        Firefox extensions are packaged as .xpi files rather than plain folders, so unlike the
        Chromium browsers this reads each profile's extensions.json (Firefox's own add-on
        database), which already contains the resolved display name, version, and ID. All
        profile folders under the user's Firefox Profiles directory are scanned. Only
        user-visible, user-installed extensions are returned; hidden/built-in system add-ons
        (which can also appear under the 'app-profile' location) are filtered out. If the
        Firefox profiles path doesn't exist, warns and returns nothing.
    .OUTPUTS
        PSCustomObject with Browser, Profile, ExtensionID, Name, and Version properties.
    #>
    $ProfilesRoot = "$env:APPDATA\Mozilla\Firefox\Profiles"

    if (-not (Test-Path $ProfilesRoot)) {
        Write-Warning "Firefox profile path not found for the current user."
        return
    }

    Get-ChildItem -Path $ProfilesRoot -Directory | ForEach-Object {
        $ExtensionsJsonPath = Join-Path $_.FullName "extensions.json"
        if (-not (Test-Path $ExtensionsJsonPath)) { return }

        try {
            $ExtensionData = Get-Content -Raw -Path $ExtensionsJsonPath | ConvertFrom-Json
        } catch {
            Write-Warning "Could not parse extensions.json for Firefox profile '$($_.Name)'."
            return
        }

        $ProfileName = $_.Name
        $ExtensionData.addons |
            # Only user-visible, user-installed extensions; skip themes, locale packs, and
            # built-in/hidden system add-ons (e.g. Firefox's internal "New Tab" feature, which
            # is also recorded under location 'app-profile' but flagged hidden)
            Where-Object { $_.type -eq 'extension' -and $_.location -eq 'app-profile' -and -not $_.hidden } |
            ForEach-Object {
                $ResolvedName = if ($_.defaultLocale -and $_.defaultLocale.name) { $_.defaultLocale.name } else { "Unknown" }
                [PSCustomObject]@{
                    Browser     = "Firefox"
                    Profile     = $ProfileName
                    ExtensionID = $_.id
                    Name        = $ResolvedName
                    Version     = $_.version
                }
            }
    }
}

$Results = @(
    Get-ChromiumExtensions -BrowserName "Chrome" -ExtensionPath "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions"
    Get-ChromiumExtensions -BrowserName "Edge" -ExtensionPath "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Extensions"
    Get-FirefoxExtensions
)

$Results | Format-Table -AutoSize
