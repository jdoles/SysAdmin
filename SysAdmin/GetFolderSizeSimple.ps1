<#
    GetFolderSizeSimple.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-05-22
    Repository: https://github.com/jdoles/SysAdmin
#>
<#
.SYNOPSIS
    This script calculates the size of each folder in a specified directory and sorts them by size.
.DESCRIPTION
    This script calculates the size of each folder in a specified directory and sorts them by size. It uses PowerShell's Get-ChildItem and Measure-Object cmdlets to gather folder sizes.
.EXAMPLE
    GetFolderSize -Path "C:\temp"
.NOTES
    This script requires PowerShell 5 or higher.  It is best to choose a path other than C:\ to avoid long wait times.
.PARAMETER Path
    The root path to scan for folder sizes. Default is "C:\".
.PARAMETER OutputCsv
    The path to save the output CSV file. If not specified, the output will be displayed in the console.
.PARAMETER ExcludeFolders
    An array of folder names to exclude from the scan. This can be used to skip specific folders. Folder names are case-insensitive and are relative to the root path.
    For example, to exclude "Temp" and "Logs", use: -ExcludeFolders "Temp", "Logs".
.PARAMETER IncludeReparsePoints
    If specified, the script will include reparse points in the size calculation.  This is NOT recommended for large folders as it can significantly increase the size.
#>

param (
    [string]$Path = "C:\",
    [string]$OutputCsv = "",
    [string[]]$ExcludeFolders = @(),
    [switch]$IncludeReparsePoints
)

if (Test-Path -Path $Path) {
    Write-Host "Enumerating: $Path"
    Get-ChildItem -Path $Path -Directory | ForEach-Object {
        $folderPath = $_.FullName
        $items = $null
        if ($IncludeReparsePoints) {
            $items = Get-ChildItem -Path $folderPath -Attributes !Directory -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            $items = Get-ChildItem -Path $folderPath -Attributes !Directory+!ReparsePoint -Recurse -Force -ErrorAction SilentlyContinue
        }
        $folderSize = $items | Measure-Object -Property Length -Sum | Select-Object -ExpandProperty Sum
        $fileCount = $items.Count

        [PSCustomObject]@{
            Folder = $_.FullName
            Files = $fileCount
            SizeGB = "{0:N2}" -f ($folderSize / 1GB)
        }
    } | Sort-Object SizeGB -Descending | Format-Table -AutoSize
} else {
    Write-Host "Target path does not exist: $Path"
    exit
}

