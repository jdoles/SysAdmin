<#
    CreateSonicwallProfile.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-11-10
    Repository: https://github.com/jdoles/SysAdmin
#>
<#
    .SYNOPSIS
    Retrieves the last logon times for all Active Directory users across all domain controllers.
    .DESCRIPTION
    This script queries each domain controller in the Active Directory environment to gather the last logon times
    for all user accounts. It can optionally export the results to a CSV file and exclude disabled user accounts.
    Based on https://www.reddit.com/r/PowerShell/comments/mfvgwn/getlastlogon_get_accurate_last_logon_time_for_user/.
    .PARAMETER ExportCSV
    A boolean indicating whether to export the results to a CSV file. Defaults to $true.
    .PARAMETER CSVPath
    The file path for the CSV export. Defaults to ".\LastLogonReport.csv".
    .PARAMETER ExcludeDisabledUsers
    A switch to indicate whether to exclude disabled user accounts from the report.
    .EXAMPLE
    .\GetLastLogonTime.ps1 -ExportCSV $true -CSVPath "C:\Reports\LastLogonReport.csv" -ExcludeDisabledUsers
    Retrieves last logon times for all enabled users and exports the results to the specified CSV file.
#>

param (
    [Parameter(Mandatory=$false)]
    [bool]$ExportCSV = $true,
    [Parameter(Mandatory=$false)]
    [string]$CSVPath = ".\LastLogonReport.csv",
    [Parameter(Mandatory=$false)]
    [switch]$ExcludeDisabledUsers
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

function Get-LastLogon {
    param (
        [bool]$ExportCSV = $true,
        [string]$CSVPath = ".\LastLogonReport.csv",
        [switch]$ExcludeDisabledUsers
    )
    begin {
        $DCList = Get-ADDomainController -Filter * | Select-Object -ExpandProperty name
        if ($ExcludeDisabledUsers) {
            $UserList = Get-ADUser -Filter {Enabled -eq $true} -Properties Name, SamAccountName | Select-Object Name, SamAccountName
        } else {
            $UserList = Get-ADUser -Filter * -Properties Name, SamAccountName | Select-Object Name, SamAccountName
        }
    }

    process {
        Write-Log -Message "Starting Last Logon retrieval for $($UserList.Count) users across $($DCList.Count) domain controllers." -Level "INFO"
        foreach ($user in $UserList) {
            $samAccountName = $user.SamAccountName
            $latestLogon = 0

            foreach ($DC in $DCList) {
                #Write-Log -Message "Processing user: $samAccountName on domain controller $DC" -Level "INFO"

                $account = Get-ADUser -Filter "SamAccountName -eq '$samAccountName'" -Properties lastLogon,lastLogonTimestamp,Enabled -Server $DC

                if (!$account) {
                    Write-Log -Message "No user account found on $DC for $samAccountName" -Level "WARN"
                    continue
                }

                #Write-Log -Message "LastLogon         : $([datetime]::FromFileTime($account.lastLogon))" -Level "INFO"
                #Write-Log -Message "LastLogonTimeStamp: $([datetime]::FromFileTime($account.lastLogonTimestamp))" -Level "INFO"

                $logontime = $account.lastLogon,$account.lastLogonTimestamp |
                    Sort-Object -Descending | Select-Object -First 1

                if ($logontime -gt $latestLogon) {
                    $latestLogon = $logontime
                }
            }

            if ($account) {
                #switch ([datetime]::FromFileTime($latestLogon)) {
                #    {$_.year -eq '1600'} {
                #        "Never"
                #    }
                    #default { $_ }
                #}

                if ($ExportCSV -eq $true) {
                    $lastlogon = [PSCustomObject]@{
                        Name            = $user.Name
                        SamAccountName  = $user.SamAccountName
                        LastLogon       = if ($latestLogon -eq 0) { "Never" } else { [datetime]::FromFileTime($latestLogon) }
                        Enabled         = $account.Enabled
                    }

                    $lastlogon | Export-Csv -Path $CSVPath -NoTypeInformation -Append
                } else {
                    Write-Log -Message "User: $($user.Name) ($samAccountName) - Last Logon: $(if ($latestLogon -eq 0) { 'Never' } else { [datetime]::FromFileTime($latestLogon) })" -Level "INFO"
                }
            }

            Remove-Variable newest,lastlogon,account,logontime,lastlogontimestamp -ErrorAction SilentlyContinue
        }
    }

    end {
        Remove-Variable DCList,UserList -ErrorAction SilentlyContinue
        Write-Log -Message "Completed Last Logon retrieval." -Level "INFO"
    }
}

# Run the function
Get-LastLogon -ExportCSV $ExportCSV -CSVPath $CSVPath -ExcludeDisabledUsers:$ExcludeDisabledUsers