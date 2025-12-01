<#
    CheckMailRecords.ps1
    Author: Justin Doles
    Requires: PowerShell 5 or higher
    Updated: 2025-11-18
    Repository: https://github.com/jdoles/SysAdmin
#>
<#
    .SYNOPSIS
        This script checks the DKIM, SPF, DMARC, and MX records for a list of domains and provides detailed information about each record.
    .DESCRIPTION
        The script accepts a list of domains and checks their DNS records for DKIM, SPF,
        DMARC, and MX. It provides detailed information about each record, including validity,
        policies, and configurations. The results can be exported to JSON and CSV formats.
    .PARAMETER Domains
        An array of domain names to check.
    .PARAMETER ExportJson
        Switch to export the results to a JSON file.
    .PARAMETER ExportCsv
        Switch to export the results to CSV files.
    .PARAMETER OutputPath
        The directory path where the output files will be saved. Default is the current directory.
    .EXAMPLE
        .\CheckMailRecords.ps1 -Domains "example.com", "contoso.com" -ExportJson -ExportCsv -OutputPath "C:\Reports"
        This command checks the specified domains and exports the results to JSON and CSV files in the C:\Reports directory.
#>

param (
    [Parameter(Mandatory=$true)]
    [string[]]$Domains,
    [Parameter(Mandatory=$false)]
    [switch]$ExportJson,
    [Parameter(Mandatory=$false)]
    [switch]$ExportCsv,
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\"
)

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

function Parse-DMARCRecord {
    param (
        [Parameter(Mandatory=$true)]
        [string]$DMARCRecord
    )
    $dmarcInfo = @{}
    $tags = $DMARCRecord -split ";"
    foreach ($tag in $tags) {
        $keyValue = $tag.Trim() -split "="
        if ($keyValue.Count -eq 2) {
            $dmarcInfo[$keyValue[0].Trim()] = $keyValue[1].Trim()
        }
    }

    # Overall DMARC Record Validity
    if ($dmarcInfo.ContainsKey("v") -and $dmarcInfo["v"] -eq "DMARC1" -and $dmarcInfo.ContainsKey("p")) {
        $dmarcInfo["RecordValidity"] = "Valid"
        if ($dmarcInfo["p"] -in @("quarantine", "reject")) {
            $dmarcInfo["RecordValidity"] = "Valid (Enforced Policy)"
        } elseif ($dmarcInfo["p"] -eq "none") {
            $dmarcInfo["RecordValidity"] = "Valid (Monitoring Only)"
        }
        else {
            $dmarcInfo["RecordValidity"] = "Invalid"
        }
    } else {
        $dmarcInfo["RecordValidity"] = "Invalid"
    }

    # Version
    switch ($dmarcInfo["v"]) {
        "DMARC1" { $dmarcInfo["Version"] = "DMARC Version 1" }
        default { $dmarcInfo["Version"] = "Unknown Version" }
    }

    # Policy
    switch ($dmarcInfo["p"]) {
        "none" { $dmarcInfo["PolicyDescription"] = "No specific action is requested." }
        "quarantine" { $dmarcInfo["PolicyDescription"] = "Emails that fail DMARC checks should be treated with suspicion." }
        "reject" { $dmarcInfo["PolicyDescription"] = "Emails that fail DMARC checks should be rejected outright." }
        default { $dmarcInfo["PolicyDescription"] = "Unknown policy." }
    }

    # Subdomain policy; if not specified, defaults to main policy
    switch ($dmarcInfo["sp"]) {
        "none" { $dmarcInfo["SubdomainPolicyDescription"] = "No specific action is requested for subdomains." }
        "quarantine" { $dmarcInfo["SubdomainPolicyDescription"] = "Subdomain emails that fail DMARC checks should be treated with suspicion." }
        "reject" { $dmarcInfo["SubdomainPolicyDescription"] = "Subdomain emails that fail DMARC checks should be rejected outright." }
        default { $dmarcInfo["SubdomainPolicyDescription"] = "Unknown subdomain policy." }
    }
    
    # Percentage of emails to which the DMARC policy is applied
    switch ($dmarcInfo["pct"]) {
        {$_ -match '^\d+$'} { $dmarcInfo["PercentageApplied"] = [int]$dmarcInfo["pct"] }
        default { $dmarcInfo["PercentageApplied"] = 100 }
    }

    # Forensic reporting options
    switch ($dmarcInfo["fo"]) {
        "0" { $dmarcInfo["ForensicOptions"] = "Generate report if both DKIM and SPF fail." }
        "1" { $dmarcInfo["ForensicOptions"] = "Generate report if either DKIM or SPF fails." }
        "d" { $dmarcInfo["ForensicOptions"] = "Generate report if DKIM fails." }
        "s" { $dmarcInfo["ForensicOptions"] = "Generate report if SPF fails." }
        default { $dmarcInfo["ForensicOptions"] = "Not Specified" }
    }

    # Report format
    switch ($dmarcInfo["rf"]) {
        "afrf" { $dmarcInfo["ReportFormat"] = "Aggregate Feedback Report Format (AFRF)" }
        default { $dmarcInfo["ReportFormat"] = "Not Specified" }
    }

    # Report interval
    switch ($dmarcInfo["ri"]) {
        {$_ -match '^\d+$'} { $dmarcInfo["ReportInterval"] = [int]$dmarcInfo["ri"] }
        default { $dmarcInfo["ReportInterval"] = 86400 } # Default to 86400 seconds (1 day)
    }

    # Optional Forensic Report URI
    switch ($dmarcInfo["ruf"]) {
        {$_ -ne $null} { $dmarcInfo["ForensicReportURI"] = $dmarcInfo["ruf"] }
        default { $dmarcInfo["ForensicReportURI"] = "Not Specified" }
    }

    # Optional Aggregate Report URI
    switch ($dmarcInfo["rua"]) {
        {$_ -ne $null} { $dmarcInfo["AggregateReportURI"] = $dmarcInfo["rua"] }
        default { $dmarcInfo["AggregateReportURI"] = "Not Specified" }
    }

    # Optional SPF Alignment
    switch ($dmarcInfo["aspf"]) {
        "r" { $dmarcInfo["SPFAlignment"] = "Relaxed" }
        "s" { $dmarcInfo["SPFAlignment"] = "Strict" }
        default { $dmarcInfo["SPFAlignment"] = "Not Implemented" }
    }
    # Optional DKIM Alignment
    switch ($dmarcInfo["adkim"]) {
        "r" { $dmarcInfo["DKIMAlignment"] = "Relaxed" }
        "s" { $dmarcInfo["DKIMAlignment"] = "Strict" }
        default { $dmarcInfo["DKIMAlignment"] = "Not Implemented" }
    }

    return $dmarcInfo
}

# Common DKIM selectors used by popular email services
$dkimSelectors = @(
    "selector1", # Google / Microsoft 365
    "selector2", # GOogle / Microsoft 365
    "s1", # SendGrid
    "s2", # SendGrid
    "k1", # Mailchimp / Mandrill
    "ctct1", # Constant Contact
    "ctct2", # COnstant Contact
    "zendesk1", # Zendesk
    "zendesk2", # Zendesk
    "sig1", # iCloud
    "litesrv" # MailerLite
)

$domainInfo = @{
    Timestamp = (Get-Date).ToString("o")
    Domains = @()
}

if ($ExportJson -or $ExportCsv) {
    if (-not $OutputPath.EndsWith("\")) {
        $OutputPath += "\"
    }
}

foreach ($domain in $domains) {
    Write-Log -Message "Processing domain: $domain" -Level "INFO"
    $dkimRecords = @()
    $dkimStatus = $null
    $spfRecords = @()
    $spfStatus = $null
    $mxRecords = @()
    $mxStatus = $null
    $dmarcRecords = @()
    $dmarcStatus = $null

    Write-Log -Message "Checking MX records for $domain" -Level "INFO"
    try {
        $txtRecords = (Resolve-DnsName -Name $domain -Type MX -ErrorAction Stop)
        foreach ($record in $txtRecords) {
            $mxRecords += [PSCustomObject]@{
                Record   = $record.Exchange
                Data     = ""
                Preference = $record.Preference
            }
        }

        Write-Log -Message "Found $($mxRecords.Count) MX records for $domain" -Level "INFO"
        if ($mxRecords.Count -gt 0) {
            $mxStatus = "Valid"
        } else {
            Write-Log -Message "No MX records found for $domain" -Level "WARN"
            $mxStatus = "Invalid (No Record)"
        }
    } catch {
        # No record found or other error
        $mxStatus = "Invalid (No Record)"
    }

    Write-Log -Message "Checking DKIM records for $domain" -Level "INFO"
    foreach ($selector in $dkimSelectors) {
        $dkimRecord = "$selector._domainkey.$domain"
        try {
            $txtRecords = (Resolve-DnsName -Name $dkimRecord -Type TXT -ErrorAction Stop).Strings -join ""
            foreach ($record in $txtRecords) {
                $dkimRecords += [PSCustomObject]@{
                    Record = $dkimRecord
                    Data   = $record
                }
            }

            Write-Log -Message "Found DKIM $($dkimRecords.Count) records for $domain" -Level "INFO"
        } catch {
            # No record found or other error
            $dkimStatus = "Invalid (No Record)"
        }
    }

    Write-Log -Message "Checking SPF record for $spfRecordName" -Level "INFO"
    $spfRecordName = "$domain"
    try {
        $txtRecords = (Resolve-DnsName -Name $spfRecordName -Type TXT -ErrorAction Stop).Strings
        foreach ($record in $txtRecords) {
            if ($record -like "v=spf1*") {
                $spfRecords += [PSCustomObject]@{
                    Record = $spfRecordName
                    Data   = $record
                }
            }
        }

        Write-Log -Message "Found SPF $($spfRecords.Count) records for $domain" -Level "INFO"
        if ($spfRecords.Count -eq 1) {
            $spfStatus = "Valid"
        } elseif ($spfRecords.Count -gt 1) {
            $spfStatus = "Invalid (Multiple Records)"
        } else {
            $spfStatus = "Invalid (No Record)"
        }
    } catch {
        # No record found or other error
        Write-Log -Message "No SPF record found for $domain" -Level "WARN"
        $spfStatus = "Invalid (No Record)"
    }

    Write-Log -Message "Checking DMARC record for $domain" -Level "INFO"
    try {
        $txtRecords = (Resolve-DnsName -Name "_dmarc.$domain" -Type TXT -ErrorAction Stop).Strings
        foreach ($record in $txtRecords) {
            $dmarcInfo = Parse-DMARCRecord -DMARCRecord $record
            $dmarcRecords += [PSCustomObject]@{
                Record  = "_dmarc.$domain"
                Data    = $record
                Details = $dmarcInfo
            }
        }
        Write-Log -Message "Found DMARC $($dmarcRecords.Count) records for $domain" -Level "INFO"
        if ($dmarcRecords.Count -eq 1) {
            $dmarcStatus = $dmarcRecords[0].Details.RecordValidity
        } elseif ($dmarcRecords.Count -gt 1) {
            $dmarcStatus = "Invalid (Multiple Records)"
        } else {
            $dmarcStatus = "Invalid (No Record)"
        }
    } catch {
        # No record found or other error
        Write-Log -Message "No DMARC record found for $domain" -Level "WARN"
        $dmarcStatus = "Invalid (No Record)"
    }

    # Update
    $domainInfo.Domains += @{
        $domain = @{
            Info = @{
                DMARCStatus = $dmarcStatus
                DKIMStatus = if ($dkimRecords.Count -gt 0) { "Valid" } else { "Invalid (No Record)" }
                SPFStatus = $spfStatus
                MXStatus = $mxStatus
            }
            DKIM = $dkimRecords
            SPF  = $spfRecords
            MXRecords = $mxRecords
            DMARC = $dmarcRecords
        }
    }
}

if ($ExportJson) {
    Write-Log -Message "Saving results to $OutputPath" -Level "INFO"
    $domainInfo | ConvertTo-Json -Depth 10 | Out-File -FilePath "$OutputPath\DomainEmailAuthRecords.json" -Encoding UTF8
}

$domainInfo.Domains | ForEach-Object {
    $domainName = $_.Keys | Select-Object -First 1
    $domainData = $_.$domainName
    Write-Host "Domain: $domainName" -ForegroundColor Yellow
    Write-Host "  DMARC Status: $($domainData.Info.DMARCStatus)"
    Write-Host "  DKIM Status: $($domainData.Info.DKIMStatus)"
    Write-Host "  SPF Status: $($domainData.Info.SPFStatus)"
    Write-Host "  MX Status: $($domainData.Info.MXStatus)"

    if ($ExportCsv) {
        Write-Log -Message "Exporting records for $domainName to CSV" -Level "INFO"
        $domainData.DKIM | Select-Object @{Name="Domain";Expression={$domainName}},@{Name="Record Type";Expression={"DKIM"}},* | Export-Csv -Path "$OutputPath$domainName-Records.csv" -NoTypeInformation -Force
        $domainData.SPF | Select-Object @{Name="Domain";Expression={$domainName}},@{Name="Record Type";Expression={"SPF"}},* | Export-Csv -Path "$OutputPath$domainName-Records.csv" -NoTypeInformation -Append
        $domainData.MXRecords | Select-Object @{Name="Domain";Expression={$domainName}},@{Name="Record Type";Expression={"MX"}},* | Export-Csv -Path "$OutputPath$domainName-Records.csv" -NoTypeInformation -Append
        $domainData.DMARC | Select-Object @{Name="Domain";Expression={$domainName}},@{Name="Record Type";Expression={"DMARC"}},Record,Data | Export-Csv -Path "$OutputPath$domainName-Records.csv" -NoTypeInformation -Append
    }
}