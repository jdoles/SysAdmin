#Requires -Version 3.0
<#
.SYNOPSIS
    Reports on Windows Update patch status for local or remote computers.

.DESCRIPTION
    Uses the Windows Update Agent COM API to retrieve installed, pending, and failed
    patches. Supports Windows 10 / Windows Server 2012 R2 and later.
    No third-party modules required.

.PARAMETER ComputerName
    One or more computer names to query. Defaults to the local machine.

.PARAMETER Status
    Filter results by patch state: All, Installed, Pending, Missing, Failed. Defaults to All.
    Missing  = available from Windows Update but not yet downloaded.
    Pending  = downloaded to the machine, waiting to be installed or needs a reboot.

.PARAMETER OutputFormat
    Output format: Table, JSON, or CSV. Defaults to Table.

.PARAMETER OutputPath
    File path for JSON or CSV output. If omitted, output goes to the console.

.PARAMETER MaxHistory
    Maximum number of update history records to retrieve per computer. Defaults to 200.

.PARAMETER Credential
    Alternate credentials for remote computer queries.

.EXAMPLE
    .\Get-PatchStatus.ps1
    Reports all patch statuses for the local machine in table format.

.EXAMPLE
    .\Get-PatchStatus.ps1 -ComputerName Server01, Server02 -Status Failed -OutputFormat CSV -OutputPath C:\Reports\failed_patches.csv

.EXAMPLE
    .\Get-PatchStatus.ps1 -ComputerName PC01 -Status Pending -OutputFormat JSON

.EXAMPLE
    Get-Content computers.txt | .\Get-PatchStatus.ps1 -OutputFormat CSV -OutputPath C:\Reports\patches.csv
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('CN', 'Host')]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [ValidateSet('All', 'Installed', 'Pending', 'Missing', 'Failed')]
    [string]$Status = 'All',

    [ValidateSet('Table', 'JSON', 'CSV')]
    [string]$OutputFormat = 'Table',

    [string]$OutputPath,

    [int]$MaxHistory = 200,

    [System.Management.Automation.PSCredential]$Credential
)

begin {
    # Script block runs on each target computer (local or remote)
    $queryScriptBlock = {
        param([int]$MaxHistory, [string]$StatusFilter)

        $results = New-Object System.Collections.ArrayList

        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        $osCaption  = if ($osInfo) { $osInfo.Caption }         else { 'Unknown' }
        $osBuild    = if ($osInfo) { $osInfo.BuildNumber }     else { 'Unknown' }
        $computer   = $env:COMPUTERNAME

        try {
            $session  = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
        } catch {
            Write-Warning "[$computer] Could not create Windows Update session: $_"
            return $results
        }

        # --- Missing / Pending updates ---
        # Missing = not yet downloaded; Pending = downloaded, awaiting install or reboot
        if ($StatusFilter -in 'All', 'Missing', 'Pending') {
            try {
                $searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
                foreach ($update in $searchResult.Updates) {
                    $updateStatus = if ($update.IsDownloaded) { 'Pending' } else { 'Missing' }

                    # Skip if caller asked for only one of the two
                    if ($StatusFilter -eq 'Pending' -and $updateStatus -eq 'Missing') { continue }
                    if ($StatusFilter -eq 'Missing'  -and $updateStatus -eq 'Pending') { continue }

                    # COM collections need explicit indexing on PS 3/4
                    $kbList = @()
                    for ($i = 0; $i -lt $update.KBArticleIDs.Count; $i++) {
                        $kbList += "KB$($update.KBArticleIDs.Item($i))"
                    }
                    $kb       = if ($kbList.Count -gt 0) { $kbList -join ', ' } else { 'N/A' }
                    $category = if ($update.Categories.Count -gt 0) { $update.Categories.Item(0).Name } else { '' }

                    $null = $results.Add([PSCustomObject]@{
                        ComputerName = $computer
                        OS           = $osCaption
                        OSBuild      = $osBuild
                        KB           = $kb
                        Title        = $update.Title
                        Status       = $updateStatus
                        InstalledOn  = $null
                        Category     = $category
                        Severity     = if ($update.MsrcSeverity) { $update.MsrcSeverity } else { 'N/A' }
                        Size_MB      = [Math]::Round($update.MaxDownloadSize / 1MB, 1)
                    })
                }
            } catch {
                Write-Warning "[$computer] Failed to query missing/pending updates: $_"
            }
        }

        # --- Update history (Installed / Failed) ---
        if ($StatusFilter -in 'All', 'Installed', 'Failed') {
            try {
                $totalCount = $searcher.GetTotalHistoryCount()
                $fetchCount = [Math]::Min($totalCount, $MaxHistory)

                if ($fetchCount -gt 0) {
                    $history = $searcher.QueryHistory(0, $fetchCount)
                    foreach ($item in $history) {
                        $rc = $item.ResultCode

                        $include = $StatusFilter -eq 'All' -or
                                   ($StatusFilter -eq 'Installed' -and $rc -in 2, 3) -or
                                   ($StatusFilter -eq 'Failed'    -and $rc -in 4, 5)

                        if (-not $include) { continue }

                        $statusText = switch ($rc) {
                            0 { 'Not Started' }
                            1 { 'In Progress' }
                            2 { 'Installed' }
                            3 { 'Installed (with errors)' }
                            4 { 'Failed' }
                            5 { 'Aborted' }
                            default { "Unknown ($rc)" }
                        }

                        $kb = if ($item.Title -match 'KB(\d+)') { "KB$($Matches[1])" } else { 'N/A' }
                        $category = if ($item.Categories.Count -gt 0) { $item.Categories.Item(0).Name } else { '' }

                        $null = $results.Add([PSCustomObject]@{
                            ComputerName = $computer
                            OS           = $osCaption
                            OSBuild      = $osBuild
                            KB           = $kb
                            Title        = $item.Title
                            Status       = $statusText
                            InstalledOn  = $item.Date
                            Category     = $category
                            Severity     = 'N/A'
                            Size_MB      = 'N/A'
                        })
                    }
                }
            } catch {
                Write-Warning "[$computer] Failed to query update history: $_"
            }
        }

        return $results
    }

    $allResults = New-Object System.Collections.ArrayList
}

process {
    foreach ($computer in $ComputerName) {
        Write-Verbose "Querying $computer ..."

        $isLocal = ($computer -eq $env:COMPUTERNAME) -or
                   ($computer -eq 'localhost') -or
                   ($computer -eq '127.0.0.1')

        if ($isLocal) {
            try {
                $records = & $queryScriptBlock $MaxHistory $Status
                foreach ($r in $records) { $null = $allResults.Add($r) }
            } catch {
                Write-Warning "[$computer] Local query failed: $_"
            }
        } else {
            $invokeParams = @{
                ComputerName = $computer
                ScriptBlock  = $queryScriptBlock
                ArgumentList = $MaxHistory, $Status
                ErrorAction  = 'Stop'
            }
            if ($Credential) { $invokeParams['Credential'] = $Credential }

            try {
                $records = Invoke-Command @invokeParams
                foreach ($r in $records) {
                    # Strip PSRemoting metadata properties
                    $null = $allResults.Add([PSCustomObject]@{
                        ComputerName = $r.ComputerName
                        OS           = $r.OS
                        OSBuild      = $r.OSBuild
                        KB           = $r.KB
                        Title        = $r.Title
                        Status       = $r.Status
                        InstalledOn  = $r.InstalledOn
                        Category     = $r.Category
                        Severity     = $r.Severity
                        Size_MB      = $r.Size_MB
                    })
                }
            } catch {
                Write-Warning "[$computer] Remote query failed: $_"
                Write-Warning "  Ensure WinRM is enabled: Enable-PSRemoting -Force"
            }
        }
    }
}

end {
    if ($allResults.Count -eq 0) {
        Write-Warning "No patch records found matching the specified criteria."
        return
    }

    # Sort: Failed first, then Missing, Pending, then Installed; newest first within each group
    $sortOrder = @{ Failed = 0; Aborted = 1; Missing = 2; Pending = 3; 'In Progress' = 4; 'Installed (with errors)' = 5; Installed = 6 }
    $sorted = $allResults | Sort-Object `
        @{ Expression = { if ($sortOrder.ContainsKey($_.Status)) { $sortOrder[$_.Status] } else { 99 } } },
        @{ Expression = 'InstalledOn'; Descending = $true },
        'ComputerName'

    switch ($OutputFormat) {
        'Table' {
            $sorted | Format-Table -AutoSize -Property `
                ComputerName, KB, Status, InstalledOn, Category, Severity, Title
        }

        'JSON' {
            $json = $sorted | ConvertTo-Json -Depth 3
            if ($OutputPath) {
                $json | Out-File -FilePath $OutputPath -Encoding UTF8
                Write-Host "JSON saved to: $OutputPath"
            } else {
                $json
            }
        }

        'CSV' {
            if ($OutputPath) {
                $sorted | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
                Write-Host "CSV saved to: $OutputPath"
            } else {
                $sorted | ConvertTo-Csv -NoTypeInformation
            }
        }
    }
}
