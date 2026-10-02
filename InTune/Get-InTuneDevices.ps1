#Requires -Version 7.0
<#
.SYNOPSIS
    Microsoft Intune Windows Device IP Address Report

.DESCRIPTION
    Reports the IP address information Intune holds for every Intune-managed
    Windows device - the same values shown in the Intune admin center under
    Devices > <device> > Hardware. For each device the report includes:
      - Device name, primary user, serial number, manufacturer, and model
      - Wi-Fi IPv4 address and subnet address
      - Wired IPv4 address(es)
      - Wi-Fi and Ethernet MAC addresses
      - OS version, compliance state, and last check-in time

    IP data lives in the managed device's hardwareInformation object, which is
    only exposed on the Microsoft Graph beta endpoint and is only populated
    when a single device is requested with $select=hardwareInformation (list
    calls return it empty). The script therefore lists all Windows devices
    first, then fetches each device's hardwareInformation using Graph JSON
    batching (20 devices per request) to keep the number of round trips low.

    Outputs:
      - A CSV file with one row per device
      - An HTML summary report for quick visual review

.PARAMETER TenantDomain
    Your tenant's primary domain (e.g., contoso.com). Used to target the
    interactive sign-in at the right tenant and for labeling the report.

.PARAMETER OutputPath
    Directory where the report files will be written. Defaults to
    .\IntuneDeviceIpReport_<timestamp> under the current directory.

.PARAMETER SkipModuleCheck
    Skip the required module version check at startup (use only if modules
    are pre-validated).

.PARAMETER AppId
    Azure AD Application (client) ID for app-only (certificate-based)
    authentication. Must be used together with -TenantId and either
    -CertificateThumbprint or -CertificatePath. Recommended for unattended /
    scheduled runs. The app registration created by
    Create-EnterpriseApplication.ps1 (fluffy-system) already holds the
    DeviceManagementManagedDevices.Read.All application permission this
    report needs.

.PARAMETER TenantId
    Azure AD Tenant ID (GUID). Required for app-only authentication.

.PARAMETER CertificateThumbprint
    Thumbprint of a certificate already installed in the current user's
    certificate store. Used for app-only authentication. Takes precedence
    over -CertificatePath.

.PARAMETER CertificatePath
    Path to a PFX certificate file. Used for app-only authentication when the
    certificate is not installed in the local certificate store.

.PARAMETER CertificatePassword
    Password for the PFX file specified in -CertificatePath (as a
    SecureString).

.EXAMPLE
    .\Get-InTuneDevices.ps1 -TenantDomain "contoso.com"

.EXAMPLE
    .\Get-InTuneDevices.ps1 -TenantDomain "contoso.com" -OutputPath "C:\Reports\Intune"

.EXAMPLE
    .\Get-InTuneDevices.ps1 -TenantDomain "contoso.com" -AppId "00000000-0000-0000-0000-000000000000" `
        -TenantId "00000000-0000-0000-0000-000000000000" -CertificateThumbprint "ABCDEF1234567890"

.NOTES
    Requires DeviceManagementManagedDevices.Read.All - delegated (with an
    Intune role such as Intune Read Only Operator, Intune Administrator, or
    Global Reader) for interactive auth, or the application permission for
    app-only auth.
    IP values are whatever the device last reported to Intune: the Wi-Fi
    address refreshes on check-in, wired addresses roughly daily. Devices
    that haven't checked in recently may show stale or empty values.
    Required Module Versions:
      Microsoft.Graph.Authentication    2.30.0+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantDomain,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "",

    [Parameter(Mandatory = $false)]
    [switch]$SkipModuleCheck,

    [Parameter(Mandatory = $false)]
    [string]$AppId = "",

    [Parameter(Mandatory = $false)]
    [string]$TenantId = "",

    [Parameter(Mandatory = $false)]
    [string]$CertificateThumbprint = "",

    [Parameter(Mandatory = $false)]
    [string]$CertificatePath = "",

    [Parameter(Mandatory = $false)]
    [securestring]$CertificatePassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

#region ─── INITIALIZATION ──────────────────────────────────────────────────────

$ScriptVersion = "2.0.0"
$RunTimestamp  = Get-Date -Format "yyyyMMdd_HHmmss"

if (-not $OutputPath) {
    $OutputPath = Join-Path (Get-Location) "IntuneDeviceIpReport_$RunTimestamp"
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$LogFile    = Join-Path $OutputPath "IntuneDeviceIpReport_Log_$RunTimestamp.txt"
$CsvOutput  = Join-Path $OutputPath "IntuneDeviceIpReport_$RunTimestamp.csv"
$HtmlReport = Join-Path $OutputPath "IntuneDeviceIpReport_$RunTimestamp.html"

$GraphBeta = "https://graph.microsoft.com/beta"

# Graph JSON batching caps a single $batch request at 20 sub-requests.
$BatchSize = 20

# How many passes to make over sub-requests that come back throttled (429) or
# transiently failed (5xx) before giving up on them.
$MaxBatchAttempts = 4

# Auth mode + shared state
$script:AppOnlyAuth = [bool]($AppId -and $TenantId -and ($CertificateThumbprint -or $CertificatePath))
$script:CertObject  = $null

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped message to the run log and the console.
    .DESCRIPTION
        Appends "[timestamp][LEVEL] message" to the run's log file and echoes
        it to the host, colored by level.
    .PARAMETER Message
        The text to log.
    .PARAMETER Level
        INFO, WARN, or ERROR. Defaults to INFO.
    #>
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        "INFO"  { Write-Host $line -ForegroundColor Cyan }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
    }
}

function Get-HashValue {
    <#
    .SYNOPSIS
        Safely reads a key from a (possibly null) hashtable.
    .DESCRIPTION
        Invoke-MgGraphRequest returns responses as nested hashtables. Under
        Set-StrictMode, chaining into a missing nested object throws, so all
        response lookups go through this helper instead.
    .PARAMETER Table
        The hashtable (or $null) to read from.
    .PARAMETER Key
        The key to look up.
    .PARAMETER Default
        Value returned when the table is null or the key is absent/null.
    #>
    param($Table, [string]$Key, $Default = $null)
    if ($Table -is [System.Collections.IDictionary] -and $Table.Contains($Key) -and $null -ne $Table[$Key]) {
        return $Table[$Key]
    }
    return $Default
}

function ConvertTo-HtmlText {
    <#
    .SYNOPSIS
        HTML-encodes a value for safe insertion into the report.
    .PARAMETER Value
        The value to encode. $null becomes an empty string.
    #>
    param($Value)
    if ($null -eq $Value) { return "" }
    return ([string]$Value) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
}

function Format-DateValue {
    <#
    .SYNOPSIS
        Formats a Graph date/time value as "yyyy-MM-dd HH:mm" (UTC).
    .DESCRIPTION
        Accepts either a [datetime] or an ISO 8601 string. Returns the raw
        value as a string if it can't be parsed, or "" for empty input.
    .PARAMETER Value
        The date/time value to format.
    #>
    param($Value)
    if ($null -eq $Value -or "$Value" -eq "") { return "" }
    try   { return ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') }
    catch { return [string]$Value }
}

#endregion

#region ─── MODULE VALIDATION ───────────────────────────────────────────────────

function Test-RequiredModules {
    <#
    .SYNOPSIS
        Verifies the PowerShell modules this report depends on are installed.
    .DESCRIPTION
        Logs each required module's installed version, warns when one is
        older than the tested minimum, and throws with an Install-Module
        command when any are missing.
    #>
    Write-Log "Checking required PowerShell modules..." -Level INFO

    $required = @(
        @{ Name = "Microsoft.Graph.Authentication"; MinVersion = "2.30.0" }
    )

    $missing  = @()
    $outdated = @()

    foreach ($mod in $required) {
        $installed = Get-Module -ListAvailable -Name $mod.Name |
                     Sort-Object Version -Descending | Select-Object -First 1
        if (-not $installed) {
            $missing += $mod.Name
            Write-Log "MISSING: $($mod.Name) (requires $($mod.MinVersion)+)" -Level WARN
        } elseif ($installed.Version -lt [version]$mod.MinVersion) {
            $outdated += "$($mod.Name) (installed: $($installed.Version), required: $($mod.MinVersion))"
            Write-Log "OUTDATED: $($mod.Name) $($installed.Version) - update to $($mod.MinVersion)+" -Level WARN
        } else {
            Write-Log "OK: $($mod.Name) $($installed.Version)" -Level INFO
        }
    }

    if ($missing.Count -gt 0) {
        Write-Log "MISSING MODULES - install with:" -Level ERROR
        Write-Log "  Install-Module $($missing -join ', ') -Force -AllowClobber" -Level ERROR
        throw "Required modules are missing. Install them and re-run."
    }
    if ($outdated.Count -gt 0) {
        Write-Log "Some modules are outdated. Update with: Update-Module" -Level WARN
    }
    Write-Log "Module check complete." -Level INFO
}

#endregion

#region ─── CONNECTION HELPERS ──────────────────────────────────────────────────

function Resolve-AuthCertificate {
    <#
    .SYNOPSIS
        Loads the app-only auth certificate from a PFX file when needed.
    .DESCRIPTION
        When app-only auth is configured with -CertificatePath (and no
        -CertificateThumbprint), loads the PFX into $script:CertObject for
        Connect-MgGraph -Certificate. Does nothing otherwise.
    #>
    if ($script:AppOnlyAuth -and $CertificatePath -and -not $CertificateThumbprint) {
        if ($CertificatePassword) {
            $script:CertObject = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
                $CertificatePath, $CertificatePassword)
        } else {
            $script:CertObject = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
                $CertificatePath)
        }
    }
}

function Connect-ReportServices {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph using app-only or interactive auth.
    .DESCRIPTION
        Uses certificate-based app-only auth when -AppId, -TenantId, and a
        certificate are supplied; otherwise signs in interactively with the
        DeviceManagementManagedDevices.Read.All delegated scope, targeted at
        -TenantDomain.
    #>
    Write-Log "Connecting to Microsoft Graph..." -Level INFO
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.0.0 -ErrorAction Stop
    Resolve-AuthCertificate

    if ($script:AppOnlyAuth) {
        Write-Log "Using app-only (certificate) authentication." -Level INFO
        $params = @{ ClientId = $AppId; TenantId = $TenantId; NoWelcome = $true }
        if ($CertificateThumbprint) { $params['CertificateThumbprint'] = $CertificateThumbprint }
        else                        { $params['Certificate']            = $script:CertObject }
        Connect-MgGraph @params -ErrorAction Stop
    } else {
        Write-Log "Using interactive (delegated) authentication." -Level INFO
        Connect-MgGraph -TenantId $TenantDomain -Scopes "DeviceManagementManagedDevices.Read.All" -NoWelcome -ErrorAction Stop
    }

    $ctx = Get-MgContext
    $who = if ($ctx.AuthType -eq 'AppOnly') { "app $($ctx.ClientId)" } else { $ctx.Account }
    Write-Log "Connected to Microsoft Graph as $who (tenant $($ctx.TenantId))." -Level INFO
}

#endregion

#region ─── DEVICE COLLECTION ───────────────────────────────────────────────────

function Get-WindowsManagedDevices {
    <#
    .SYNOPSIS
        Lists every Intune-managed Windows device.
    .DESCRIPTION
        Pages through beta /deviceManagement/managedDevices filtered to
        operatingSystem eq 'Windows', selecting only the properties the report
        uses. hardwareInformation is deliberately not requested here - Graph
        returns it empty on list calls; see Get-DeviceHardwareInfo.
    .OUTPUTS
        System.Collections.Generic.List[object] of device hashtables.
    #>
    Write-Log "Retrieving Intune-managed Windows devices..." -Level INFO

    $select = @(
        'id', 'deviceName', 'userPrincipalName', 'userDisplayName', 'operatingSystem', 'osVersion',
        'complianceState', 'lastSyncDateTime', 'serialNumber', 'manufacturer', 'model',
        'wiFiMacAddress', 'ethernetMacAddress', 'azureADDeviceId'
    ) -join ','
    $uri = "$GraphBeta/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=$select&`$top=1000"

    $devices = [System.Collections.Generic.List[object]]::new()
    while ($uri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        foreach ($d in @(Get-HashValue $page 'value' @())) { $devices.Add($d) }
        $uri = Get-HashValue $page '@odata.nextLink'
    }

    Write-Log "Found $($devices.Count) Windows device(s)." -Level INFO
    return , $devices
}

function Get-DeviceHardwareInfo {
    <#
    .SYNOPSIS
        Fetches hardwareInformation for each device via Graph JSON batching.
    .DESCRIPTION
        Sends GET managedDevices/{id}?$select=id,hardwareInformation for each
        device, 20 per $batch request. Sub-requests that come back throttled
        (429) or with a transient 5xx are retried on a later pass, honoring the
        largest Retry-After seen, up to $MaxBatchAttempts passes.
    .PARAMETER DeviceIds
        Intune managed device IDs to look up.
    .OUTPUTS
        Hashtable keyed by device ID. Each value is a hashtable with either
        Hardware (the hardwareInformation hashtable) or Error (a message).
    #>
    param([string[]]$DeviceIds)

    Write-Log "Retrieving hardware/network details for $($DeviceIds.Count) device(s) in batches of $BatchSize..." -Level INFO

    $results = @{}
    $pending = @($DeviceIds)
    $attempt = 0

    while ($pending.Count -gt 0 -and $attempt -lt $MaxBatchAttempts) {
        $attempt++
        $retry      = [System.Collections.Generic.List[string]]::new()
        $retryAfter = 0

        if ($attempt -gt 1) {
            Write-Log "Retry pass $attempt of ${MaxBatchAttempts}: $($pending.Count) device(s) remaining." -Level WARN
        }

        for ($i = 0; $i -lt $pending.Count; $i += $BatchSize) {
            $chunk = $pending[$i..([math]::Min($i + $BatchSize, $pending.Count) - 1)]

            $body = @{
                requests = @($chunk | ForEach-Object {
                    @{ id = $_; method = 'GET'; url = "/deviceManagement/managedDevices/$_`?`$select=id,hardwareInformation" }
                })
            } | ConvertTo-Json -Depth 4

            try {
                $resp = Invoke-MgGraphRequest -Method POST -Uri "$GraphBeta/`$batch" -Body $body -ContentType 'application/json' -ErrorAction Stop
            } catch {
                Write-Log "Batch request failed for $($chunk.Count) device(s): $($_.Exception.Message)" -Level WARN
                foreach ($id in $chunk) { $retry.Add($id) }
                $retryAfter = [math]::Max($retryAfter, 10)
                continue
            }

            foreach ($r in @(Get-HashValue $resp 'responses' @())) {
                $id     = [string](Get-HashValue $r 'id')
                $status = [int](Get-HashValue $r 'status' 0)
                $rBody  = Get-HashValue $r 'body'

                if ($status -eq 200) {
                    $results[$id] = @{ Hardware = (Get-HashValue $rBody 'hardwareInformation' @{}); Error = $null }
                } elseif ($status -eq 429 -or $status -ge 500) {
                    $retry.Add($id)
                    $ra = 0
                    [void][int]::TryParse([string](Get-HashValue (Get-HashValue $r 'headers') 'Retry-After' '0'), [ref]$ra)
                    $retryAfter = [math]::Max($retryAfter, [math]::Max($ra, 5))
                } else {
                    $msg = Get-HashValue (Get-HashValue $rBody 'error') 'message' 'Unknown error'
                    $results[$id] = @{ Hardware = $null; Error = "HTTP $status - $msg" }
                }
            }

            $done = [math]::Min($i + $BatchSize, $pending.Count)
            Write-Progress -Activity "Retrieving hardware details (pass $attempt)" -Status "$done of $($pending.Count)" `
                -PercentComplete ([math]::Floor(($done / $pending.Count) * 100))
        }
        Write-Progress -Activity "Retrieving hardware details (pass $attempt)" -Completed

        $pending = @($retry)
        if ($pending.Count -gt 0 -and $attempt -lt $MaxBatchAttempts) {
            Write-Log "$($pending.Count) request(s) throttled or failed transiently - waiting $retryAfter second(s) before retrying." -Level WARN
            Start-Sleep -Seconds $retryAfter
        }
    }

    foreach ($id in $pending) {
        $results[$id] = @{ Hardware = $null; Error = "Gave up after $MaxBatchAttempts attempt(s) (throttled or transient error)" }
    }

    $failed = @($results.Values | Where-Object { $_.Error }).Count
    if ($failed -gt 0) {
        Write-Log "Hardware details could not be retrieved for $failed device(s); see the IPStatus column." -Level WARN
    }
    Write-Log "Hardware/network detail retrieval complete." -Level INFO
    return $results
}

function ConvertTo-DeviceRow {
    <#
    .SYNOPSIS
        Builds one report row from a device and its hardwareInformation.
    .DESCRIPTION
        Maps Graph's ipAddressV4 (shown in the portal as the Wi-Fi IPv4
        address) and wiredIPv4Addresses to report columns, and combines them
        into a de-duplicated IPAddresses column. Prefers the hardwareInformation
        serial/manufacturer/model, falling back to the device-level values.
    .PARAMETER Device
        A device hashtable from Get-WindowsManagedDevices.
    .PARAMETER HardwareResult
        The matching entry from Get-DeviceHardwareInfo (Hardware / Error).
    .OUTPUTS
        PSCustomObject
    #>
    param($Device, $HardwareResult)

    $hw    = Get-HashValue $HardwareResult 'Hardware'
    $lookupError = Get-HashValue $HardwareResult 'Error' 'No hardware lookup result'

    $wifiIp  = [string](Get-HashValue $hw 'ipAddressV4' '')
    $wiredIp = @(@(Get-HashValue $hw 'wiredIPv4Addresses' @()) | Where-Object { $_ })
    $allIps  = @(@($wifiIp) + $wiredIp | Where-Object { $_ } | Select-Object -Unique)

    $ipStatus = if (-not $hw)          { "Lookup failed: $lookupError" }
                elseif ($allIps.Count) { "OK" }
                else                   { "No IP reported" }

    [PSCustomObject]@{
        DeviceName         = Get-HashValue $Device 'deviceName' ''
        PrimaryUser        = Get-HashValue $Device 'userPrincipalName' ''
        UserDisplayName    = Get-HashValue $Device 'userDisplayName' ''
        IPAddresses        = $allIps -join '; '
        WiFiIPv4Address    = $wifiIp
        SubnetAddress      = [string](Get-HashValue $hw 'subnetAddress' '')
        WiredIPv4Addresses = $wiredIp -join '; '
        WiFiMacAddress     = Get-HashValue $Device 'wiFiMacAddress' ''
        EthernetMacAddress = Get-HashValue $Device 'ethernetMacAddress' ''
        SerialNumber       = Get-HashValue $hw 'serialNumber' (Get-HashValue $Device 'serialNumber' '')
        Manufacturer       = Get-HashValue $hw 'manufacturer' (Get-HashValue $Device 'manufacturer' '')
        Model              = Get-HashValue $hw 'model' (Get-HashValue $Device 'model' '')
        OSVersion          = Get-HashValue $Device 'osVersion' ''
        ComplianceState    = Get-HashValue $Device 'complianceState' ''
        LastSyncUtc        = Format-DateValue (Get-HashValue $Device 'lastSyncDateTime')
        IPStatus           = $ipStatus
        IntuneDeviceId     = Get-HashValue $Device 'id' ''
        EntraDeviceId      = Get-HashValue $Device 'azureADDeviceId' ''
    }
}

#endregion

#region ─── EXPORT ───────────────────────────────────────────────────────────────

function Export-CsvReport {
    <#
    .SYNOPSIS
        Writes the report rows to a UTF-8 CSV file.
    .PARAMETER Rows
        The report rows to export.
    .PARAMETER Path
        Destination CSV path.
    #>
    param($Rows, $Path)
    $Rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Log "CSV report saved to: $Path" -Level INFO
}

function Export-HtmlReport {
    <#
    .SYNOPSIS
        Writes the HTML summary report.
    .DESCRIPTION
        Renders summary cards (device totals and IP coverage) and a per-device
        table of name, user, IP addresses, MAC addresses, model, and last
        check-in. Full detail (serial, OS version, IDs) is in the CSV.
    .PARAMETER Rows
        The report rows to render.
    .PARAMETER Path
        Destination HTML path.
    #>
    param($Rows, $Path)

    $Rows          = @($Rows)
    $TotalDevices  = $Rows.Count
    $WithIp        = @($Rows | Where-Object { $_.IPStatus -eq 'OK' }).Count
    $NoIp          = @($Rows | Where-Object { $_.IPStatus -eq 'No IP reported' }).Count
    $LookupFailed  = @($Rows | Where-Object { $_.IPStatus -like 'Lookup failed*' }).Count

    $TableRows = $Rows | ForEach-Object {
        $ipCell = if ($_.IPStatus -eq 'OK') {
            $parts = @()
            if ($_.WiFiIPv4Address)    { $parts += "Wi-Fi: $(ConvertTo-HtmlText $_.WiFiIPv4Address)" }
            if ($_.WiredIPv4Addresses) { $parts += "Wired: $(ConvertTo-HtmlText $_.WiredIPv4Addresses)" }
            $parts -join '<br>'
        } else {
            "<span class='muted'>$(ConvertTo-HtmlText $_.IPStatus)</span>"
        }
        $macParts = @()
        if ($_.WiFiMacAddress)     { $macParts += "Wi-Fi: $(ConvertTo-HtmlText $_.WiFiMacAddress)" }
        if ($_.EthernetMacAddress) { $macParts += "Ethernet: $(ConvertTo-HtmlText $_.EthernetMacAddress)" }

        "<tr><td>$(ConvertTo-HtmlText $_.DeviceName)</td><td>$(ConvertTo-HtmlText $_.PrimaryUser)</td><td>$ipCell</td><td>$(ConvertTo-HtmlText $_.SubnetAddress)</td><td>$($macParts -join '<br>')</td><td>$(ConvertTo-HtmlText "$($_.Manufacturer) $($_.Model)".Trim())</td><td>$(ConvertTo-HtmlText $_.LastSyncUtc)</td></tr>"
    }
    if ($TotalDevices -eq 0) {
        $TableRows = "<tr><td colspan='7' style='text-align:center;color:#7f8c8d;font-style:italic'>No Intune-managed Windows devices were found.</td></tr>"
    }

    $Html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Intune Windows Device IP Report</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', Arial, sans-serif; background: #f5f7fa; color: #2c3e50; }
  .header { background: #020024; background: linear-gradient(90deg, rgba(2, 0, 36, 1) 0%, rgba(9, 9, 121, 1) 44%, rgba(0, 212, 255, 1) 100%); color: #fff; padding: 40px 48px; }
  .header h1 { font-size: 26px; font-weight: 700; margin-bottom: 8px; }
  .header p  { font-size: 14px; opacity: 0.85; }
  .container { max-width: 1400px; margin: 0 auto; padding: 32px 24px; }
  .section-title { font-size: 20px; font-weight: 700; margin: 32px 0 16px; border-left: 4px solid #2980b9; padding-left: 12px; }
  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 16px; margin-bottom: 32px; }
  .card { background: #fff; border-radius: 10px; padding: 20px 16px; text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,.07); }
  .card .val { font-size: 34px; font-weight: 800; color: #2980b9; }
  .card .lbl { font-size: 12px; color: #7f8c8d; margin-top: 4px; text-transform: uppercase; letter-spacing: .5px; }
  table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 10px; overflow: hidden;
          box-shadow: 0 2px 8px rgba(0,0,0,.07); margin-bottom: 32px; }
  thead { background: #2c3e50; color: #fff; }
  th { padding: 12px 14px; text-align: left; font-size: 13px; font-weight: 600; }
  td { padding: 10px 14px; font-size: 13px; border-bottom: 1px solid #ecf0f1; vertical-align: top; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #f8f9fa; }
  .muted { color: #7f8c8d; font-style: italic; }
  .note { font-size: 13px; color: #7f8c8d; margin-bottom: 16px; }
  footer { text-align: center; padding: 24px; font-size: 12px; color: #95a5a6; }
</style>
</head>
<body>
<div class="header">
  <h1>&#x1F4BB; Intune Windows Device IP Report</h1>
  <p><strong>Tenant:</strong> $(ConvertTo-HtmlText $TenantDomain) &nbsp;|&nbsp;
     <strong>Generated:</strong> $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC</p>
</div>

<div class="container">

  <div class="section-title">Summary</div>
  <div class="cards">
    <div class="card"><div class="val">$TotalDevices</div><div class="lbl">Windows Devices</div></div>
    <div class="card"><div class="val">$WithIp</div><div class="lbl">With IP Address</div></div>
    <div class="card"><div class="val">$NoIp</div><div class="lbl">No IP Reported</div></div>
    <div class="card"><div class="val">$LookupFailed</div><div class="lbl">Lookup Failed</div></div>
  </div>

  <div class="section-title">Devices</div>
  <p class="note">IP addresses are as last reported by the device to Intune (Wi-Fi on check-in, wired roughly daily) and may be stale for devices that haven't synced recently. Serial number, OS version, compliance state, and device IDs are in the CSV.</p>
  <table>
    <thead><tr><th>Device Name</th><th>Primary User</th><th>IPv4 Address(es)</th><th>Subnet</th><th>MAC Address(es)</th><th>Model</th><th>Last Sync (UTC)</th></tr></thead>
    <tbody>$($TableRows -join '')</tbody>
  </table>

</div>
<footer>Generated by Get-InTuneDevices.ps1 v$ScriptVersion &nbsp;|&nbsp;
  For internal use only. Contains device and network information.</footer>
</body>
</html>
"@

    $Html | Out-File -FilePath $Path -Encoding UTF8
    Write-Log "HTML report saved to: $Path" -Level INFO
}

#endregion

#region ─── MAIN ORCHESTRATION ──────────────────────────────────────────────────

function Invoke-IntuneDeviceIpReport {
    <#
    .SYNOPSIS
        Runs the report end to end.
    .DESCRIPTION
        Validates modules, connects to Graph, collects Windows devices and
        their hardware/network details, builds the report rows, writes the
        CSV and HTML outputs, and disconnects.
    #>
    Write-Log "======================================================" -Level INFO
    Write-Log " Intune Windows Device IP Report" -Level INFO
    Write-Log " Tenant  : $TenantDomain" -Level INFO
    Write-Log " Output  : $OutputPath" -Level INFO
    Write-Log "======================================================" -Level INFO

    if (-not $SkipModuleCheck) { Test-RequiredModules }

    Connect-ReportServices

    try {
        $Devices  = Get-WindowsManagedDevices
        $DeviceIds = @($Devices | ForEach-Object { $_['id'] })
        $Hardware = if ($DeviceIds.Count) { Get-DeviceHardwareInfo -DeviceIds $DeviceIds } else { @{} }

        $ReportRows = @($Devices | ForEach-Object {
            ConvertTo-DeviceRow -Device $_ -HardwareResult $Hardware[$_['id']]
        } | Sort-Object DeviceName)

        Export-CsvReport -Rows $ReportRows -Path $CsvOutput
        Export-HtmlReport -Rows $ReportRows -Path $HtmlReport

        Write-Log "" -Level INFO
        Write-Log "============ REPORT COMPLETE ============" -Level INFO
        Write-Log "Windows devices        : $($ReportRows.Count)" -Level INFO
        Write-Log "With IP address        : $(@($ReportRows | Where-Object { $_.IPStatus -eq 'OK' }).Count)" -Level INFO
        Write-Log "No IP reported         : $(@($ReportRows | Where-Object { $_.IPStatus -eq 'No IP reported' }).Count)" -Level INFO
        Write-Log "Hardware lookup failed : $(@($ReportRows | Where-Object { $_.IPStatus -like 'Lookup failed*' }).Count)" -Level INFO
        Write-Log "" -Level INFO
        Write-Log "Reports saved to: $OutputPath" -Level INFO
        Write-Log "  CSV Report  : $CsvOutput" -Level INFO
        Write-Log "  HTML Report : $HtmlReport" -Level INFO
        Write-Log "  Log File    : $LogFile" -Level INFO
        Write-Log "==========================================" -Level INFO
    } catch {
        Write-Log "Report failed: $($_.Exception.Message)" -Level ERROR
        throw
    } finally {
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
}

# Entry point
Invoke-IntuneDeviceIpReport

#endregion
