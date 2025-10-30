#Requires -Version 5.1
<#
    GetFolderSize.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-05-23
    Repository: https://github.com/jdoles/SysAdmin
#>
<#
.SYNOPSIS
    This script calculates the size of each folder in a specified directory and sorts them by size.
.DESCRIPTION
    This script calculates the size of each folder in a specified directory and sorts them by size. It uses .NET methods for better performance and handles reparse points and exclusions.
.EXAMPLE
    GetFolderSize -Path "C:\temp"
.NOTES
    This script requires PowerShell 5 or higher.  Ideally, you should choose a path other than C:\ to avoid long wait times.
.PARAMETER Path
    The root path to scan for folder sizes. Default is "C:\".
.PARAMETER OutputCsv
    The path to save the output CSV file. If not specified, the output will be displayed in the console.
.PARAMETER ExcludeFolders
    An array of folder names to exclude from the scan. This can be used to skip specific folders. Folder names are case-insensitive and are relative to the root path.
    For example, to exclude "Temp" and "Logs", use: -ExcludeFolders "Temp", "Logs".
.PARAMETER IncludeReparsePoints
    If specified, the script will include reparse points in the size calculation.  This is NOT recommended for large folders as it can significantly increase the size.
.PARAMETER MaxDepth
    The maximum depth to search for subfolders. Default is 3. Adjust this based on your needs.
.PARAMETER ShowProgress
    If specified, the script will show progress during the analysis.
.PARAMETER CalculateLargestSubfolder
    If specified, the script will calculate the largest subfolder within the largest folder found.
#>

param (
    [string]$Path = "C:\",
    [string]$OutputCsv = "",
    [string[]]$ExcludeFolders = @(),
    [switch]$IncludeReparsePoints,
    [int]$MaxDepth = 3,
    [switch]$ShowProgress,
    [switch]$CalculateLargestSubfolder
)

# Stores the results
$results = @()
# Stores the largest folder
$largestFolder = ""
# Stores the largest size
$largestSize = 0
# Stores the number of processed directories
$processedCount = 0

<# Get the size of a folder and its contents #>
function Get-FolderSizeOptimized {
    param(
        [string]$FolderPath,
        [bool]$IncludeReparse,
        [string[]]$ExcludePaths
    )

    $totalSize = 0
    $fileCount = 0
    $errors = @()

    foreach ($exclude in $ExcludePaths) {
        if ($FolderPath -like "*$exclude*") {
            return @{ Size = 0; Files = 0; Skipped = $true }
        }
    }

    # Get files in this directory
    try {
        $files = [System.IO.Directory]::EnumerateFiles($FolderPath, '*', [System.IO.SearchOption]::TopDirectoryOnly)
        foreach ($file in $files) {
            try {
                $fileInfo = [System.IO.FileInfo]::new($file)
                if (-not $IncludeReparse -and ($fileInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    continue
                }
                $totalSize += $fileInfo.Length
                $fileCount++
            } catch {
                #$errors += "Cannot access file $file : $($_.Exception.Message)"
                continue
            }
        }
    } catch {
        return @{ Size = 0; Files = 0; Skipped = $true; Error = $_.Exception.Message }
    }

    # Get subdirectories
    try {
        $subfolders = [System.IO.Directory]::EnumerateDirectories($FolderPath, '*', [System.IO.SearchOption]::TopDirectoryOnly)
        foreach ($subfolder in $subfolders) {
            try {
                $subResult = Get-FolderSizeOptimized -FolderPath $subfolder -IncludeReparse $IncludeReparse -ExcludePaths $ExcludePaths
                $totalSize += $subResult.Size
                $fileCount += $subResult.Files
                #if ($subResult.Error) { $errors += $subResult.Error }
            } catch {
                #$errors += "Cannot access subfolder $subfolder : $($_.Exception.Message)"
                continue
            }
        }
    } catch {
        #$errors += "Cannot enumerate subfolders in $FolderPath : $($_.Exception.Message)"
    }

    return @{
        Size = $totalSize
        Files = $fileCount
        Skipped = $false
        #Error  = ($errors -join "; ")
    }
}

<# Find the largest subfolder within a specified folder path #>
function Find-LargestSubfolder {
    param(
        [string]$RootPath,
        [int]$CurrentDepth = 0,
        [int]$MaxDepth = 3
    )

    if ($CurrentDepth -ge $MaxDepth) {
        return @{ Path = ""; Size = 0 }
    }

    $largestSub = @{ Path = ""; Size = 0 }

    try {
        $subfolders = Get-ChildItem -Path $RootPath -Directory -Force -ErrorAction SilentlyContinue

        foreach ($subfolder in $subfolders) {
            $subResult = Get-FolderSizeOptimized -FolderPath $subfolder.FullName -IncludeReparse $IncludeReparsePoints -ExcludePaths $ExcludeFolders

            if ($subResult.Size -gt $largestSub.Size) {
                $largestSub = @{
                    Path = $subfolder.FullName
                    Size = $subResult.Size
                }
            }

            $deepResult = Find-LargestSubfolder -RootPath $subfolder.FullName -CurrentDepth ($CurrentDepth + 1) -MaxDepth $MaxDepth
            if ($deepResult.Size -gt $largestSub.Size) {
                $largestSub = $deepResult
            }
        }
    } catch {
        # Skip folders we can't access
    }

    return $largestSub
}

<# Main script execution #>
$startTime = (Get-Date).Ticks
if (-not (Test-Path -Path $Path)) {
    Write-Error "Target path does not exist: $Path"
    exit 1
}

Write-Host "Analyzing folder sizes in: $Path" -ForegroundColor Green
Write-Host "Exclusions: $($ExcludeFolders -join ', ')" -ForegroundColor Yellow

$directories = Get-ChildItem -Path $Path -Directory -Force -ErrorAction SilentlyContinue
$totalDirs = $directories.Count

Write-Host "Found $totalDirs directories to analyze..." -ForegroundColor Cyan

foreach ($dir in $directories) {
    $processedCount++

    if ($ShowProgress) {
        $percentComplete = [math]::Round(($processedCount / $totalDirs) * 100, 1)
        Write-Progress -Activity "Analyzing Folders" -Status "Processing: $($dir.Name)" -PercentComplete $percentComplete
    }

    $folderInfo = Get-FolderSizeOptimized -FolderPath $dir.FullName -IncludeReparse $IncludeReparsePoints -ExcludePaths $ExcludeFolders

    if (-not $folderInfo.Skipped) {
        $sizeGB = $folderInfo.Size / 1GB

        if ($folderInfo.Size -gt $largestSize) {
            $largestSize = $folderInfo.Size
            $largestFolder = $dir.FullName
        }

        # Status is Partial if any error, otherwise OK
        $status = if ($folderInfo.Error) { "Partial" } else { "OK" }

        $results += [PSCustomObject]@{
            Folder = $dir.FullName
            Files = $folderInfo.Files
            SizeGB = "{0:N2}" -f $sizeGB
            SizeMB = "{0:N0}" -f ($folderInfo.Size / 1MB)
            Status = $status
            #Errors = $folderInfo.Error
        }
    }
    else {
        Write-Warning "Skipped or failed to process: $($dir.FullName)"
    }
}

if ($ShowProgress) {
    Write-Progress -Activity "Analyzing Folders" -Completed
}

$sortedResults = $results | Sort-Object { [double]$_.SizeGB } -Descending

Write-Host "`n=== FOLDER SIZE ANALYSIS RESULTS ===" -ForegroundColor Green
$sortedResults | Format-Table -AutoSize

if ($largestFolder) {
    Write-Host "`n=== LARGEST FOLDER ANALYSIS ===" -ForegroundColor Yellow
    Write-Host "Largest top-level folder: $largestFolder" -ForegroundColor Cyan
    Write-Host "Size: $("{0:N2}" -f ($largestSize / 1GB)) GB" -ForegroundColor Cyan

    if($CalculateLargestSubfolder) {
        Write-Host "`nFinding largest subfolder (up to $MaxDepth levels deep)..." -ForegroundColor Yellow
        $largestSubfolder = Find-LargestSubfolder -RootPath $largestFolder -MaxDepth $MaxDepth

        if ($largestSubfolder.Path) {
            Write-Host "Largest subfolder: $($largestSubfolder.Path)" -ForegroundColor Magenta
            Write-Host "Size: $("{0:N2}" -f ($largestSubfolder.Size / 1GB)) GB" -ForegroundColor Magenta
        }
        else {
            Write-Host "No significant subfolders found or access denied." -ForegroundColor Yellow
        }
    }
}

if ($OutputCsv) {
    try {
        $sortedResults | Export-Csv -Path $OutputCsv -NoTypeInformation -Force
        Write-Host "`nResults exported to: $OutputCsv" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to export CSV: $($_.Exception.Message)"
    }
}

# Calculate execution time
$executionTime = [DateTime]($(Get-Date).Ticks - $startTime)
$executionMessage = ""
if ($executionTime.Minute -gt 0) {
    $executionMessage = "$($executionTime.Minute) minutes and $($executionTime.Second) seconds"
} else {
    $executionMessage = "$($executionTime.Second) seconds"
}
Write-Host "`nAnalysis complete! Processed $processedCount directories in $executionMessage." -ForegroundColor Green
