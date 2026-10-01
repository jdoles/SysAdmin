#Requires -Version 5.1
<#
.SYNOPSIS
    Clears the Chrome, Edge, and/or Firefox cache for one or more users, or for every user on the computer.
.DESCRIPTION
    Intended to run as SYSTEM from an RMM tool. For each targeted user profile, deletes the contents of the
    browser cache folders (Chrome/Edge: Cache, Code Cache, GPUCache in every browser profile; Firefox: cache2
    in every Firefox profile). Cookies, history, saved passwords, and extensions are not touched.

    With -ClearHistory, Chrome and Edge browsing history is also deleted (History, Visited Links, Top Sites,
    Shortcuts, and Network Action Predictor files in every browser profile). Bookmarks and open tabs are kept.
    Firefox history is not cleared because Firefox stores history and bookmarks in the same database
    (places.sqlite), and deleting it would risk losing bookmarks.

    Browsers hold locks on these files while running, so files in use are skipped and reported. Use
    -ForceCloseBrowsers to close the targeted users' browser processes first so everything can be cleared.
    History files are always locked while the browser is open.

    Every parameter can also be supplied through an environment variable of the same name (usernames,
    browsers, clearHistory, forceCloseBrowsers) for RMM tools that pass script variables that way.
    Command-line parameters take precedence.
.PARAMETER UserName
    One or more usernames (profile folder name or account name) to clear. Accepts an array or a single
    comma-separated string. If omitted, all user profiles on the computer are cleared.
.PARAMETER Browser
    Which browsers to clear: Chrome, Edge, Firefox. Accepts an array or a comma-separated string.
    Defaults to all three.
.PARAMETER ClearHistory
    Also delete browsing history (Chrome and Edge only).
.PARAMETER ForceCloseBrowsers
    Close the targeted users' browser processes before clearing. Only processes owned by the targeted users
    are closed.
.EXAMPLE
    .\Clear-BrowserData.ps1
    Clears Chrome, Edge, and Firefox cache for every user on the computer.
.EXAMPLE
    .\Clear-BrowserData.ps1 -UserName jsmith -Browser Chrome,Edge -ForceCloseBrowsers
    Closes jsmith's Chrome and Edge windows, then clears their cache.
.EXAMPLE
    .\Clear-BrowserData.ps1 -Browser Chrome,Edge -ClearHistory -ForceCloseBrowsers
    Closes Chrome and Edge for every user, then clears their cache and browsing history.
.NOTES
    Author: Justin Doles
    Requires: PowerShell 5.1 or higher. Run as SYSTEM or an administrator to clear other users' cache.
#>

[CmdletBinding()]
param (
    [string[]]$UserName,
    [string[]]$Browser,
    [switch]$ClearHistory,
    [switch]$ForceCloseBrowsers
)

# Chromium browsers (Chrome, Edge) share the same profile layout, so their cache and history paths are
# built from each browser's "User Data" folder. "*" matches every browser profile (Default, Profile 1, ...).
$ChromiumCache = @('Cache\*', 'Code Cache\*', 'GPUCache\*')
$ChromiumHistory = @('History*', 'Visited Links', 'Top Sites*', 'Shortcuts*', 'Network Action Predictor*')

# Per-browser settings: the process name, plus the items (relative to the user profile) to delete.
$BrowserInfo = @{
    Chrome  = @{
        Process      = 'chrome'
        CachePaths   = $ChromiumCache | ForEach-Object { "AppData\Local\Google\Chrome\User Data\*\$_" }
        HistoryPaths = $ChromiumHistory | ForEach-Object { "AppData\Local\Google\Chrome\User Data\*\$_" }
    }
    Edge    = @{
        Process      = 'msedge'
        CachePaths   = $ChromiumCache | ForEach-Object { "AppData\Local\Microsoft\Edge\User Data\*\$_" }
        HistoryPaths = $ChromiumHistory | ForEach-Object { "AppData\Local\Microsoft\Edge\User Data\*\$_" }
    }
    Firefox = @{
        Process      = 'firefox'
        CachePaths   = @('AppData\Local\Mozilla\Firefox\Profiles\*\cache2\*')
        # History lives in places.sqlite alongside bookmarks, so it is intentionally not cleared.
        HistoryPaths = @()
    }
}

function Get-UserProfiles {
    <#
    .SYNOPSIS
        Returns the real (non-system) user profiles on the computer.
    .DESCRIPTION
        Queries Win32_UserProfile for non-special profiles (excludes SYSTEM, LocalService, NetworkService)
        and returns each one's SID, profile path, profile folder name, and account name. The account name is
        resolved from the SID when possible, since the profile folder name can differ from the username
        (e.g. "jsmith.CONTOSO"). Profiles whose folder no longer exists are skipped.
    .OUTPUTS
        PSCustomObject with SID, Path, FolderName, and AccountName properties.
    #>
    Get-CimInstance -ClassName Win32_UserProfile -Filter 'Special = FALSE' |
        Where-Object { $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) } |
        ForEach-Object {
            $AccountName = $null
            try {
                $AccountName = (New-Object System.Security.Principal.SecurityIdentifier($_.SID)).
                    Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
            }
            catch {
                # Orphaned or unresolvable SID (e.g. deleted domain account); fall back to the folder name.
            }

            [PSCustomObject]@{
                SID         = $_.SID
                Path        = $_.LocalPath
                FolderName  = Split-Path -Path $_.LocalPath -Leaf
                AccountName = $AccountName
            }
        }
}

function Stop-UserBrowser {
    <#
    .SYNOPSIS
        Closes a browser's processes that belong to a specific user.
    .DESCRIPTION
        Finds running processes with the given name and stops only those whose owner SID matches the
        given user's SID, so other users' sessions are left alone.
    .PARAMETER ProcessName
        The browser process name without ".exe" (e.g. "chrome").
    .PARAMETER SID
        The SID of the user whose processes should be closed.
    .OUTPUTS
        System.Int32 - the number of processes stopped.
    #>
    param (
        [string]$ProcessName,
        [string]$SID
    )

    $Stopped = 0
    Get-CimInstance -ClassName Win32_Process -Filter "Name = '$ProcessName.exe'" | ForEach-Object {
        $Owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue
        if ($Owner.Sid -eq $SID) {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $Stopped++
        }
    }

    if ($Stopped -gt 0) {
        # Give the browser a moment to release its file locks.
        Start-Sleep -Seconds 2
    }
    $Stopped
}

function Remove-BrowserData {
    <#
    .SYNOPSIS
        Deletes the files and folders matching a set of wildcard paths.
    .DESCRIPTION
        Expands each wildcard path (e.g. "...\User Data\*\Cache\*" or "...\User Data\*\History*") and deletes
        every matching item, recursing into folders. Items that are locked or otherwise can't be deleted are
        skipped rather than stopping the run.
    .PARAMETER Path
        One or more full paths, which may contain wildcards, to delete.
    .OUTPUTS
        System.Int32 - the number of items that could not be deleted.
    #>
    param (
        [string[]]$Path
    )

    Get-Item -Path $Path -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable RemoveErrors
    $RemoveErrors.Count
}

# --- Resolve parameters (command line first, then RMM environment variables, then defaults) ---

if (-not $UserName -and $env:usernames -and $env:usernames -ne 'null') { $UserName = $env:usernames }
if (-not $Browser -and $env:browsers -and $env:browsers -ne 'null') { $Browser = $env:browsers }
if (-not $ClearHistory -and $env:clearHistory -eq 'true') { $ClearHistory = $true }
if (-not $ForceCloseBrowsers -and $env:forceCloseBrowsers -eq 'true') { $ForceCloseBrowsers = $true }

$UserName = @($UserName -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Browser = @($Browser -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Browser.Count -eq 0) { $Browser = @('Chrome', 'Edge', 'Firefox') }

$InvalidBrowsers = $Browser | Where-Object { $BrowserInfo.Keys -notcontains $_ }
if ($InvalidBrowsers) {
    Write-Host "[Error] Unknown browser(s): $($InvalidBrowsers -join ', '). Valid values: Chrome, Edge, Firefox."
    exit 1
}

# --- Pick the target users ---

$ExitCode = 0
$AllProfiles = @(Get-UserProfiles)

if ($UserName.Count -gt 0) {
    $TargetProfiles = foreach ($Name in $UserName) {
        $Match = $AllProfiles | Where-Object { $_.FolderName -eq $Name -or $_.AccountName -eq $Name }
        if ($Match) {
            $Match
        }
        else {
            Write-Host "[Error] No profile found for '$Name'."
            $ExitCode = 1
        }
    }
}
else {
    $TargetProfiles = $AllProfiles
}

$TargetProfiles = @($TargetProfiles)
if ($TargetProfiles.Count -eq 0) {
    Write-Host '[Error] No user profiles to clear. Profiles on this computer:'
    $AllProfiles | Format-Table FolderName, AccountName, Path -AutoSize | Out-String | Write-Host
    exit 1
}

# --- Clear the cache ---

foreach ($UserProfile in $TargetProfiles) {
    Write-Host "Clearing browser data for $($UserProfile.FolderName)"

    foreach ($Name in $Browser) {
        $Info = $BrowserInfo[$Name]
        $CachePaths = @($Info.CachePaths | ForEach-Object { Join-Path -Path $UserProfile.Path -ChildPath $_ })
        $HistoryPaths = @()
        if ($ClearHistory) {
            $HistoryPaths = @($Info.HistoryPaths | ForEach-Object { Join-Path -Path $UserProfile.Path -ChildPath $_ })
            if ($HistoryPaths.Count -eq 0) {
                Write-Host "  ${Name}: history is not cleared for this browser (shares a database with bookmarks)."
            }
        }

        if (-not (Get-Item -Path ($CachePaths + $HistoryPaths) -Force -ErrorAction SilentlyContinue)) {
            Write-Host "  ${Name}: nothing to clear, skipping."
            continue
        }

        if ($ForceCloseBrowsers) {
            $Stopped = Stop-UserBrowser -ProcessName $Info.Process -SID $UserProfile.SID
            if ($Stopped -gt 0) { Write-Host "  ${Name}: closed $Stopped process(es)." }
        }

        # Clear cache, then history if requested, reporting each separately.
        $Targets = [ordered]@{ cache = $CachePaths }
        if ($HistoryPaths.Count -gt 0) { $Targets.history = $HistoryPaths }

        foreach ($Target in $Targets.GetEnumerator()) {
            $Failed = Remove-BrowserData -Path $Target.Value
            if ($Failed -gt 0) {
                Write-Host "  ${Name}: $($Target.Key) cleared, but $Failed item(s) were in use and skipped. Use -ForceCloseBrowsers to clear them."
            }
            else {
                Write-Host "  ${Name}: $($Target.Key) cleared."
            }
        }
    }
}

exit $ExitCode
