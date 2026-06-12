<#
.SYNOPSIS
    Finds and optionally deletes files older than a specified number of days.

.DESCRIPTION
    Searches a target directory for files matching optional name and extension
    filters that are older than a given age. Supports -WhatIf to preview
    deletions without making any changes.

.PARAMETER Path
    The directory to search. Required.

.PARAMETER DaysOld
    Files last written more than this many days ago will be targeted. Required.

.PARAMETER Filter
    Wildcard pattern to match file names (e.g. "backup_*"). Defaults to "*".

.PARAMETER Extension
    File extension to restrict results (e.g. ".log", ".tmp"). Omit to include all.

.PARAMETER Recurse
    Search subdirectories recursively.

.PARAMETER WhatIf
    Show which files would be deleted without actually deleting them.

.EXAMPLE
    .\Remove-OldFiles.ps1 -Path "C:\Logs" -DaysOld 30 -Extension ".log" -WhatIf
    Preview .log files in C:\Logs older than 30 days.

.EXAMPLE
    .\Remove-OldFiles.ps1 -Path "C:\Backups" -DaysOld 90 -Filter "backup_*" -Recurse
    Delete files matching "backup_*" older than 90 days, searching recursively.

.NOTES
    Author: Justin Doles
    Date: 2026-06-12
    Requires: PowerShell 5 or higher
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$Path,

    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$DaysOld,

    [Parameter()]
    [string]$Filter = "*",

    [Parameter()]
    [string]$Extension,

    [Parameter()]
    [switch]$Recurse
)

# Warn if the -Filter parameter is missing
if (-not $PSBoundParameters.ContainsKey('Filter')) {
    Write-Warning "No -Filter specified. This will target ALL files older than $DaysOld day(s) in '$Path'."
}

# Set the date cutoff
$cutoff = (Get-Date).AddDays(-$DaysOld)

$getChildParams = @{
    Path    = $Path
    File    = $true
    Filter  = $Filter
    Recurse = $Recurse.IsPresent
}

$files = Get-ChildItem @getChildParams | Where-Object {
    $_.LastWriteTime -lt $cutoff -and
    (-not $Extension -or $_.Extension -eq $Extension)
}

if (-not $files) {
    Write-Host "No files found matching the specified criteria." -ForegroundColor Yellow
    return
}

$totalSize = ($files | Measure-Object -Property Length -Sum).Sum
Write-Host "`nFound $($files.Count) file(s) totalling $([math]::Round($totalSize / 1MB, 2)) MB`n" -ForegroundColor Cyan

$deleted = 0
$failed  = 0

foreach ($file in $files) {
    if ($PSCmdlet.ShouldProcess($file.FullName, "Delete")) {
        try {
            Remove-Item -Path $file.FullName -Force -ErrorAction Stop
            $deleted++
        }
        catch {
            Write-Warning "Failed to delete '$($file.FullName)': $_"
            $failed++
        }
    }
}

if (-not $WhatIfPreference) {
    Write-Host "`nDeleted: $deleted  |  Failed: $failed" -ForegroundColor $(if ($failed) { "Yellow" } else { "Green" })
}
