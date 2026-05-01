#Requires -Version 5.1
<#
.SYNOPSIS
    DMA New Relic Export Script v1.0.1

.DESCRIPTION
    Exports New Relic dashboards, alerts, synthetic monitors, workloads, service
    level indicators, and usage analytics via the NerdGraph GraphQL API to power
    the DMA (Dynatrace Migration Assistant) New Relic to Dynatrace migration workflow.

.PARAMETER ApiKey
    New Relic User API Key (NRAK-...). Required.
    Generate at: Account Settings -> API keys -> Create a key (User key type).

.PARAMETER Accounts
    Comma-separated New Relic account IDs (e.g. "1234567,8901234").
    If omitted, all accessible accounts are auto-discovered.

.PARAMETER Region
    API region: US (default) or EU.

.PARAMETER All
    Export dashboards, alerts, synthetics, workloads, and service levels.

.PARAMETER Dashboards
    Export dashboards and NRQL widget queries.

.PARAMETER Alerts
    Export alert policies and NRQL conditions.

.PARAMETER Synthetics
    Export synthetic monitor configurations.

.PARAMETER Workloads
    Export workload configurations.

.PARAMETER ServiceLevels
    Export service level indicators (SLOs).

.PARAMETER Rbac
    Export users and groups (contains PII — opt-in).

.PARAMETER Usage
    Generate usage analytics via NRQL audit queries (opt-in).

.PARAMETER Anonymize
    Also produce a SHA-256 masked archive suitable for sharing.

.PARAMETER OutputDir
    Custom working directory. Defaults to system temp.

.PARAMETER DebugMode
    Enable verbose logging.

.EXAMPLE
    .\dma-newrelic-export.ps1 -ApiKey "NRAK-XXX" -Accounts "1234567" -All

.EXAMPLE
    .\dma-newrelic-export.ps1 -ApiKey "NRAK-XXX" -Accounts "1234567,8901234" -Dashboards -Alerts

.EXAMPLE
    .\dma-newrelic-export.ps1 -ApiKey "NRAK-XXX" -Accounts "1234567" -All -Rbac -Usage -Region EU

.NOTES
    Requirements: PowerShell 5.1+ or PowerShell 7+ on Windows, macOS, or Linux.
    Network access to https://api.newrelic.com/graphql (US) or https://api.eu.newrelic.com/graphql (EU).
    Output: dma_export_newrelic_YYYYMMDDTHHMMSSZ.tar.gz — upload to DMA New Relic App in Dynatrace.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [string]$Accounts = "",

    [ValidateSet("US", "EU")]
    [string]$Region = "US",

    [switch]$All,
    [switch]$Dashboards,
    [switch]$Alerts,
    [switch]$Synthetics,
    [switch]$Workloads,
    [switch]$ServiceLevels,
    [switch]$Rbac,
    [switch]$Usage,
    [switch]$Anonymize,

    [string]$OutputDir = "",
    [switch]$DebugMode,

    [switch]$TestAccess
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVersion    = "1.0.1"
$SchemaVersion    = "1.0"
$ApiEndpointUS    = "https://api.newrelic.com/graphql"
$ApiEndpointEU    = "https://api.eu.newrelic.com/graphql"
$ApiRetryCount    = 3
$ApiDelayMs       = 50
$EntityFetchBatch = 25
$ScriptStartTime  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$ScriptStartEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Resolve --all flag
if ($All) {
    $Dashboards    = $true
    $Alerts        = $true
    $Synthetics    = $true
    $Workloads     = $true
    $ServiceLevels = $true
}

$GraphqlEndpoint = if ($Region -eq "EU") { $ApiEndpointEU } else { $ApiEndpointUS }

if ([string]::IsNullOrEmpty($OutputDir)) {
    $OutputDir = Join-Path ([System.IO.Path]::GetTempPath()) "dma_newrelic_export_$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
}

# Skip output dir / log file creation when running --TestAccess (pure permission probe).
if (-not $TestAccess) {
    $null = New-Item -ItemType Directory -Path (Join-Path $OutputDir "_systeminfo") -Force
    $LogFile = Join-Path $OutputDir "export.log"
    $null = New-Item -ItemType File -Path $LogFile -Force
} else {
    $LogFile = $null
}

$AccountIdList = @()
if (-not [string]::IsNullOrEmpty($Accounts)) {
    $AccountIdList = @($Accounts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# =============================================================================
# LOGGING
# =============================================================================
function Write-Log {
    param([string]$Level, [string]$Message)
    $ts   = (Get-Date).ToUniversalTime().ToString("HH:mm:ss")
    $line = "[$ts] [$Level]  $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}
function Log-Info  { param([string]$m) Write-Log "INFO " $m }
function Log-Ok    { param([string]$m) Write-Log "OK   " "  ✓ $m" }
function Log-Warn  { param([string]$m) Write-Log "WARN " $m }
function Log-Error { param([string]$m) Write-Log "ERROR" $m }
function Log-Debug { param([string]$m) if ($DebugMode) { Write-Log "DEBUG" $m } }

# =============================================================================
# ACCESS TEST (--TestAccess pre-flight)
# =============================================================================

# Single-shot NerdGraph probe — no retries, short timeout. Returns @{ Code; Body; Error }.
function Invoke-Probe {
    param([string]$Query)
    $body    = @{ query = $Query } | ConvertTo-Json -Compress -Depth 5
    $headers = @{ "Content-Type" = "application/json"; "API-Key" = $ApiKey }
    try {
        $response = Invoke-RestMethod -Uri $GraphqlEndpoint -Method Post -Body $body -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        return [PSCustomObject]@{ Code = 200; Body = $response; Error = $null }
    } catch {
        $code = 0
        try { $code = [int]($_.Exception.Response.StatusCode) } catch { $code = 0 }
        return [PSCustomObject]@{ Code = $code; Body = $null; Error = $_.Exception.Message }
    }
}

function Invoke-TestAccess {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║                       DMA New Relic Access Test                          ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Testing API key permissions for: $GraphqlEndpoint" -ForegroundColor Cyan
    Write-Host ""

    $sep  = "  +----------------------------------+--------+----------------------------------+"
    $rfmt = "  | {0,-32} | {1,-6} | {2,-32} |"

    Write-Host $sep
    Write-Host ($rfmt -f "CATEGORY", "RESULT", "NOTES")
    Write-Host $sep

    $counters = @{ Pass = 0; Warn = 0; Fail = 0; Skip = 0 }
    $testAccountId = $null

    # Closure-capable helper. Mutates $counters via hashtable reference.
    $renderRow = {
        param([string]$Label, [string]$Result, [string]$Notes)
        $color = switch ($Result) {
            "PASS" { "Green" }
            "WARN" { "Yellow" }
            "FAIL" { "Red" }
            default { "DarkGray" }
        }
        Write-Host ($rfmt -f $Label, $Result, $Notes) -ForegroundColor $color
        switch ($Result) {
            "PASS" { $counters.Pass++ }
            "WARN" { $counters.Warn++ }
            "FAIL" { $counters.Fail++ }
            "SKIP" { $counters.Skip++ }
        }
    }

    $runTest = {
        param([string]$Label, [string]$Query, [scriptblock]$CountExpr)

        if ([string]::IsNullOrEmpty($Query)) {
            & $renderRow $Label "SKIP" "Account discovery failed"
            return
        }

        $r    = Invoke-Probe -Query $Query
        $code = $r.Code
        $body = $r.Body

        if ($code -ne 200) {
            $notes = switch ($code) {
                401     { "Auth error (HTTP 401)" }
                403     { "Auth error (HTTP 403)" }
                0       { "No response - check network" }
                default { "HTTP $code" }
            }
            & $renderRow $Label "FAIL" $notes
            return
        }

        if ($body.psobject.Properties['errors'] -and $body.errors -and @($body.errors).Count -gt 0) {
            $msg = [string]$body.errors[0].message
            if ($msg.Length -gt 32) { $msg = $msg.Substring(0,32) }
            & $renderRow $Label "FAIL" $msg
            return
        }

        try {
            $count = & $CountExpr $body
            if ($count -gt 0) {
                & $renderRow $Label "PASS" "$count item(s)"
            } else {
                & $renderRow $Label "WARN" "Reachable; no items found"
            }
        } catch {
            & $renderRow $Label "FAIL" "Response parse error"
        }
    }

    # 1. Credentials
    & $runTest "Credentials (user info)" `
        '{ actor { user { name email } } }' `
        { param($b) if ($b.data.actor.user.psobject.Properties['name']) { 1 } else { 0 } }

    # 2. Account discovery — capture first id for downstream tests
    if ($AccountIdList.Count -gt 0) {
        $testAccountId = $AccountIdList[0]
    } else {
        $r = Invoke-Probe -Query '{ actor { accounts { id } } }'
        if ($r.Code -eq 200 -and $r.Body -and @($r.Body.data.actor.accounts).Count -gt 0) {
            $testAccountId = $r.Body.data.actor.accounts[0].id
        }
    }
    & $runTest "Account discovery" `
        '{ actor { accounts { id name } } }' `
        { param($b) @($b.data.actor.accounts).Count }

    # 3. Organization
    & $runTest "Organization (--Rbac prereq)" `
        '{ actor { organization { id name } } }' `
        { param($b) if ($b.data.actor.organization.psobject.Properties['id']) { 1 } else { 0 } }

    # Per-account tests
    if ($testAccountId) {
        $aid = $testAccountId
        & $runTest "Dashboards" `
            "{ actor { entitySearch(query: `"type='DASHBOARD' AND accountId=$aid`") { count } } }" `
            { param($b) [int]$b.data.actor.entitySearch.count }
        & $runTest "Alert policies" `
            "{ actor { account(id: $aid) { alerts { policiesSearch { policies { id } } } } } }" `
            { param($b) @($b.data.actor.account.alerts.policiesSearch.policies).Count }
        & $runTest "NRQL alert conditions" `
            "{ actor { account(id: $aid) { alerts { nrqlConditionsSearch { nrqlConditions { id } } } } } }" `
            { param($b) @($b.data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions).Count }
        & $runTest "Synthetic monitors" `
            "{ actor { entitySearch(query: `"type='MONITOR' AND accountId=$aid`") { count } } }" `
            { param($b) [int]$b.data.actor.entitySearch.count }
        & $runTest "Workloads" `
            "{ actor { entitySearch(query: `"type='WORKLOAD' AND accountId=$aid`") { count } } }" `
            { param($b) [int]$b.data.actor.entitySearch.count }
        & $runTest "NRQL queries (--Usage prereq)" `
            "{ actor { account(id: $aid) { nrql(query: `"SELECT count(*) FROM Transaction SINCE 1 hour ago`") { results } } } }" `
            { param($b) @($b.data.actor.account.nrql.results).Count }
    } else {
        @("Dashboards", "Alert policies", "NRQL alert conditions", "Synthetic monitors", "Workloads", "NRQL queries (--Usage prereq)") | ForEach-Object {
            & $renderRow $_ "SKIP" "No account id available"
        }
    }

    # RBAC
    & $runTest "RBAC users (--Rbac prereq)" `
        '{ actor { organization { authenticationDomains(filter: {}) { authenticationDomains { id } } } } }' `
        { param($b) @($b.data.actor.organization.authenticationDomains.authenticationDomains).Count }

    Write-Host $sep
    Write-Host ("  | {0,-32}  PASS:{1,3}  WARN:{2,3}  FAIL:{3,3}  SKIP:{4,3} |" -f "SUMMARY", $counters.Pass, $counters.Warn, $counters.Fail, $counters.Skip)
    Write-Host $sep
    Write-Host ""

    if ($counters.Fail -gt 0) {
        Write-Host "  One or more categories FAILED. Fix permissions before running a full export." -ForegroundColor Red
        Write-Host ""
        return 1
    } elseif ($counters.Warn -gt 0) {
        Write-Host "  All categories reachable. WARN may indicate empty categories or missing optional scopes." -ForegroundColor Yellow
        Write-Host ""
        return 0
    } else {
        Write-Host "  All checks passed. Ready to run a full export." -ForegroundColor Green
        Write-Host ""
        return 0
    }
}

# =============================================================================
# API HELPERS
# =============================================================================
function Invoke-NerdGraph {
    param([string]$Query)

    $body    = @{ query = $Query } | ConvertTo-Json -Compress -Depth 5
    $headers = @{
        "Content-Type" = "application/json"
        "API-Key"      = $ApiKey
    }

    for ($attempt = 1; $attempt -le $ApiRetryCount; $attempt++) {
        try {
            $response = Invoke-RestMethod `
                -Uri     $GraphqlEndpoint `
                -Method  POST `
                -Headers $headers `
                -Body    $body `
                -ErrorAction Stop

            $hasErrors = $response.psobject.Properties['errors'] -and $response.errors
            if ($hasErrors) {
                Log-Warn "GraphQL errors (attempt $attempt/$ApiRetryCount): $($response.errors | ConvertTo-Json -Compress)"
            } else {
                return $response
            }
        } catch {
            $statusCode = $null
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
            if ($statusCode -eq 401) { Log-Error "Authentication failed (HTTP 401). Verify --ApiKey."; return $null }
            if ($statusCode -eq 403) { Log-Error "Permission denied (HTTP 403). Ensure the key has Full Platform Access."; return $null }
            Log-Warn "HTTP error (attempt $attempt/$ApiRetryCount): $_"
        }

        if ($attempt -lt $ApiRetryCount) {
            $sleepSecs = [Math]::Pow(2, $attempt)
            Log-Warn "Retrying in ${sleepSecs}s..."
            Start-Sleep -Seconds $sleepSecs
        }
    }

    Log-Warn "API request failed after $ApiRetryCount attempts"
    return $null
}

function Save-Json {
    param([object]$Data, [string]$Path, [switch]$AsArray)

    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

    $isCollection = $AsArray -or (
        $null -ne $Data -and
        $Data -is [System.Collections.IEnumerable] -and
        $Data -isnot [string] -and
        $Data -isnot [hashtable] -and
        $Data -isnot [System.Collections.IDictionary]
    )
    if ($isCollection) {
        $array = @($Data)
        if ($array.Count -eq 0)     { $json = "[]" }
        elseif ($array.Count -eq 1) { $json = ConvertTo-Json -InputObject $array[0] -Depth 20 -AsArray }
        else                        { $json = $array | ConvertTo-Json -Depth 20 }
    } else {
        $json = ConvertTo-Json -InputObject $Data -Depth 20
    }
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

function Count-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        $data = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($data -is [array]) { return $data.Count }
        return 0
    } catch { return 0 }
}

function Merge-Arrays {
    param([array]$A, [array]$B)
    return @($A) + @($B)
}

# =============================================================================
# ACCOUNT DISCOVERY
# =============================================================================
function Export-Accounts {
    Log-Info "Exporting account information..."
    $response = Invoke-NerdGraph '{ actor { accounts { id name } } }'
    $accounts  = if ($response) { @($response.data.actor.accounts) } else { @() }
    Save-Json -Data $accounts -Path (Join-Path $OutputDir "_systeminfo/accounts.json")
    Log-Ok "Exported $($accounts.Count) accounts"
    return $accounts
}

function Discover-AccountIds {
    Log-Info "Discovering accessible accounts..."
    $response = Invoke-NerdGraph '{ actor { accounts { id name } } }'
    if (-not $response) { Log-Error "Could not discover accounts."; exit 1 }
    $ids = @($response.data.actor.accounts | ForEach-Object { "$($_.id)" })
    if (-not $ids) { Log-Error "No accounts found."; exit 1 }
    $script:AccountIdList = $ids
    Log-Info "  Discovered accounts: $($ids -join ', ')"
}

# =============================================================================
# DASHBOARDS
# =============================================================================
function Export-DashboardsForAccount {
    param([string]$AccountId)

    $outDir = Join-Path $OutputDir "account_$AccountId/dashboards"
    $null   = New-Item -ItemType Directory -Path $outDir -Force

    Log-Info "  [Account $AccountId] Exporting dashboards..."

    # Phase 1 — discover GUIDs
    $cursor   = $null
    $allGuids = @()
    $page     = 1

    do {
        $cursorArg = if ($cursor) { ", cursor: `"$cursor`"" } else { "" }
        $query = @"
{
  actor {
    entitySearch(query: "type = 'DASHBOARD' AND accountId = $AccountId"$cursorArg) {
      results {
        entities { ... on DashboardEntityOutline { guid } }
        nextCursor
      }
    }
  }
}
"@
        $response   = Invoke-NerdGraph $query
        $results    = if ($response) { $response.data.actor.entitySearch.results } else { $null }
        $pageGuids  = if ($results)  { @($results.entities | Where-Object { $_.guid } | ForEach-Object { $_.guid }) } else { @() }
        $cursor     = if ($results)  { $results.nextCursor } else { $null }

        Log-Debug "    Page ${page}: $($pageGuids.Count) dashboard GUIDs"
        $allGuids = Merge-Arrays $allGuids $pageGuids
        $page++
        Start-Sleep -Milliseconds $ApiDelayMs
    } while ($cursor)

    Log-Debug "    Phase 1 complete: $($allGuids.Count) dashboard GUIDs"

    # Phase 2 — batch-fetch full details
    $allEntities = @()
    $start       = 0
    $batchNum    = 1

    while ($start -lt $allGuids.Count) {
        $batch       = $allGuids[$start..([Math]::Min($start + $EntityFetchBatch - 1, $allGuids.Count - 1))]
        $guidsLiteral = '["' + ($batch -join '","') + '"]'

        $detailQuery = @"
{
  actor {
    entities(guids: $guidsLiteral) {
      ... on DashboardEntity {
        guid name accountId createdAt updatedAt permissions
        owner { email userId }
        pages {
          guid name description
          widgets {
            id title
            layout { row column height width }
            visualization { id }
            rawConfiguration
          }
        }
        tags { key values }
      }
    }
  }
}
"@
        $detailResponse = Invoke-NerdGraph $detailQuery
        $batchEntities  = if ($detailResponse) {
            @($detailResponse.data.actor.entities | Where-Object { $_ -and $_.guid })
        } else { @() }
        Log-Debug "    Batch ${batchNum}: fetched $($batchEntities.Count) dashboard details"
        $allEntities = Merge-Arrays $allEntities $batchEntities
        $start += $EntityFetchBatch
        $batchNum++
        Start-Sleep -Milliseconds $ApiDelayMs
    }

    Save-Json -Data $allEntities -Path (Join-Path $outDir "dashboards.json")
    Log-Ok "  [Account $AccountId] Exported $($allEntities.Count) dashboards"
}

# =============================================================================
# ALERTS
# =============================================================================
function Export-AlertsForAccount {
    param([string]$AccountId)

    $outDir = Join-Path $OutputDir "account_$AccountId/alerts"
    $null   = New-Item -ItemType Directory -Path $outDir -Force

    Log-Info "  [Account $AccountId] Exporting alert policies..."

    $cursor     = $null
    $allPolicies = @()

    do {
        $searchArgs = if ($cursor) { "(cursor: `"$cursor`")" } else { "" }
        $query = @"
{
  actor {
    account(id: $AccountId) {
      alerts {
        policiesSearch$searchArgs {
          policies { id name incidentPreference }
          nextCursor
        }
      }
    }
  }
}
"@
        $response   = Invoke-NerdGraph $query
        $ps         = if ($response) { $response.data.actor.account.alerts.policiesSearch } else { $null }
        $items      = if ($ps)       { @($ps.policies) } else { @() }
        $cursor     = if ($ps)       { $ps.nextCursor } else { $null }
        $allPolicies = Merge-Arrays $allPolicies $items
        Start-Sleep -Milliseconds $ApiDelayMs
    } while ($cursor)

    Save-Json -Data $allPolicies -Path (Join-Path $outDir "policies.json")
    Log-Ok "  [Account $AccountId] Exported $($allPolicies.Count) alert policies"

    # --- NRQL Conditions ---
    Log-Info "  [Account $AccountId] Exporting NRQL alert conditions..."
    $cursor        = $null
    $allConditions = @()

    do {
        $searchArgs = if ($cursor) { "(cursor: `"$cursor`")" } else { "" }
        $query = @"
{
  actor {
    account(id: $AccountId) {
      alerts {
        nrqlConditionsSearch$searchArgs {
          nrqlConditions {
            id name description enabled entityGuid policyId
            nrql { query }
            expiration { closeViolationsOnExpiration expirationDuration openViolationOnExpiration }
          }
          nextCursor
        }
      }
    }
  }
}
"@
        $response    = Invoke-NerdGraph $query
        $ns          = if ($response) { $response.data.actor.account.alerts.nrqlConditionsSearch } else { $null }
        $items       = if ($ns)       { @($ns.nrqlConditions) } else { @() }
        $cursor      = if ($ns)       { $ns.nextCursor } else { $null }
        $allConditions = Merge-Arrays $allConditions $items
        Start-Sleep -Milliseconds $ApiDelayMs
    } while ($cursor)

    Save-Json -Data $allConditions -Path (Join-Path $outDir "nrql_conditions.json")
    Log-Ok "  [Account $AccountId] Exported $($allConditions.Count) NRQL alert conditions"

    # --- Notification Channels ---
    Log-Info "  [Account $AccountId] Exporting notification channels..."
    $query = @"
{
  actor {
    account(id: $AccountId) {
      aiNotifications {
        destinations { entities { id name type status isUserAuthenticated properties { key value } } }
        channels { entities { id name type destinationId product status } }
      }
    }
  }
}
"@
    $response = Invoke-NerdGraph $query
    $notif    = if ($response) { $response.data.actor.account.aiNotifications } else { $null }
    $channels = @{
        destinations = if ($notif) { @($notif.destinations.entities) } else { @() }
        channels     = if ($notif) { @($notif.channels.entities) } else { @() }
    }
    Save-Json -Data $channels -Path (Join-Path $outDir "notification_channels.json")
    Log-Ok "  [Account $AccountId] Exported $($channels.destinations.Count) destinations, $($channels.channels.Count) channels"
}

# =============================================================================
# SYNTHETICS
# =============================================================================
function Export-SyntheticsForAccount {
    param([string]$AccountId)

    $outDir = Join-Path $OutputDir "account_$AccountId/synthetics"
    $null   = New-Item -ItemType Directory -Path $outDir -Force

    Log-Info "  [Account $AccountId] Exporting synthetic monitors..."

    $cursor   = $null
    $allGuids = @()
    $page     = 1

    do {
        $cursorArg = if ($cursor) { ", cursor: `"$cursor`"" } else { "" }
        $query = @"
{
  actor {
    entitySearch(query: "type = 'MONITOR' AND accountId = $AccountId"$cursorArg) {
      results {
        entities { ... on SyntheticMonitorEntityOutline { guid } }
        nextCursor
      }
    }
  }
}
"@
        $response  = Invoke-NerdGraph $query
        $results   = if ($response) { $response.data.actor.entitySearch.results } else { $null }
        $pageGuids = if ($results)  { @($results.entities | Where-Object { $_.guid } | ForEach-Object { $_.guid }) } else { @() }
        $cursor    = if ($results)  { $results.nextCursor } else { $null }
        Log-Debug "    Page ${page}: $($pageGuids.Count) monitor GUIDs"
        $allGuids = Merge-Arrays $allGuids $pageGuids
        $page++
        Start-Sleep -Milliseconds $ApiDelayMs
    } while ($cursor)

    $allMonitors = @()
    $start       = 0
    $batchNum    = 1

    while ($start -lt $allGuids.Count) {
        $batch        = $allGuids[$start..([Math]::Min($start + $EntityFetchBatch - 1, $allGuids.Count - 1))]
        $guidsLiteral = '["' + ($batch -join '","') + '"]'

        $detailQuery = @"
{
  actor {
    entities(guids: $guidsLiteral) {
      ... on SyntheticMonitorEntity {
        guid name accountId monitorType period monitoredUrl
        monitorSummary { status locationsRunning locationsFailing successRate }
        tags { key values }
      }
    }
  }
}
"@
        $detailResponse = Invoke-NerdGraph $detailQuery
        $batchItems     = if ($detailResponse) {
            @($detailResponse.data.actor.entities | Where-Object { $_ -and $_.guid })
        } else { @() }
        Log-Debug "    Batch ${batchNum}: fetched $($batchItems.Count) monitor details"
        $allMonitors = Merge-Arrays $allMonitors $batchItems
        $start += $EntityFetchBatch
        $batchNum++
        Start-Sleep -Milliseconds $ApiDelayMs
    }

    Save-Json -Data $allMonitors -Path (Join-Path $outDir "monitors.json")
    Log-Ok "  [Account $AccountId] Exported $($allMonitors.Count) synthetic monitors"
}

# =============================================================================
# WORKLOADS
# =============================================================================
function Export-WorkloadsForAccount {
    param([string]$AccountId)

    $outDir = Join-Path $OutputDir "account_$AccountId/workloads"
    $null   = New-Item -ItemType Directory -Path $outDir -Force

    Log-Info "  [Account $AccountId] Exporting workloads..."

    $cursor   = $null
    $allGuids = @()
    $page     = 1

    do {
        $cursorArg = if ($cursor) { ", cursor: `"$cursor`"" } else { "" }
        $query = @"
{
  actor {
    entitySearch(query: "type = 'WORKLOAD' AND accountId = $AccountId"$cursorArg) {
      results {
        entities { ... on WorkloadEntityOutline { guid } }
        nextCursor
      }
    }
  }
}
"@
        $response  = Invoke-NerdGraph $query
        $results   = if ($response) { $response.data.actor.entitySearch.results } else { $null }
        $pageGuids = if ($results)  { @($results.entities | Where-Object { $_.guid } | ForEach-Object { $_.guid }) } else { @() }
        $cursor    = if ($results)  { $results.nextCursor } else { $null }
        Log-Debug "    Page ${page}: $($pageGuids.Count) workload GUIDs"
        $allGuids = Merge-Arrays $allGuids $pageGuids
        $page++
        Start-Sleep -Milliseconds $ApiDelayMs
    } while ($cursor)

    $allWorkloads = @()
    $start        = 0
    $batchNum     = 1

    while ($start -lt $allGuids.Count) {
        $batch        = $allGuids[$start..([Math]::Min($start + $EntityFetchBatch - 1, $allGuids.Count - 1))]
        $guidsLiteral = '["' + ($batch -join '","') + '"]'

        $detailQuery = @"
{
  actor {
    entities(guids: $guidsLiteral) {
      ... on WorkloadEntity {
        guid name accountId createdAt updatedAt permalink
        tags { key values }
      }
    }
  }
}
"@
        $detailResponse = Invoke-NerdGraph $detailQuery
        $batchItems     = if ($detailResponse) {
            @($detailResponse.data.actor.entities | Where-Object { $_ -and $_.guid })
        } else { @() }
        Log-Debug "    Batch ${batchNum}: fetched $($batchItems.Count) workload details"
        $allWorkloads = Merge-Arrays $allWorkloads $batchItems
        $start += $EntityFetchBatch
        $batchNum++
        Start-Sleep -Milliseconds $ApiDelayMs
    }

    Save-Json -Data $allWorkloads -Path (Join-Path $outDir "workloads.json")
    Log-Ok "  [Account $AccountId] Exported $($allWorkloads.Count) workloads"
}

# =============================================================================
# SERVICE LEVELS
# =============================================================================
function Export-ServiceLevelsForAccount {
    param([string]$AccountId)

    $outDir = Join-Path $OutputDir "account_$AccountId/service_levels"
    $null   = New-Item -ItemType Directory -Path $outDir -Force

    Log-Info "  [Account $AccountId] Exporting service level indicators..."

    $cursor        = $null
    $allIndicators = @()

    do {
        $cursorArg = if ($cursor) { "(cursor: `"$cursor`")" } else { "" }
        $query = @"
{
  actor {
    account(id: $AccountId) {
      serviceLevel {
        indicators$cursorArg {
          nextCursor
          objects {
            id name description guid entityGuid createdAt updatedAt
            events {
              account { id name }
              validEvents { from where }
              goodEvents  { from where }
              badEvents   { from where }
            }
            objectives {
              name description target
              timeWindow { rolling { count unit } }
            }
          }
        }
      }
    }
  }
}
"@
        $response  = Invoke-NerdGraph $query
        $sli       = if ($response) { $response.data.actor.account.serviceLevel.indicators } else { $null }
        $items     = if ($sli)      { @($sli.objects) } else { @() }
        $cursor    = if ($sli)      { $sli.nextCursor } else { $null }
        Log-Debug "    Fetched $($items.Count) SLIs"
        $allIndicators = Merge-Arrays $allIndicators $items
        Start-Sleep -Milliseconds $ApiDelayMs
    } while ($cursor)

    Save-Json -Data $allIndicators -Path (Join-Path $outDir "indicators.json")
    Log-Ok "  [Account $AccountId] Exported $($allIndicators.Count) service level indicators"
}

# =============================================================================
# RBAC
# =============================================================================
function Export-Users {
    Log-Info "Exporting users and groups (RBAC)..."
    $rbacDir = Join-Path $OutputDir "_rbac"
    $null    = New-Item -ItemType Directory -Path $rbacDir -Force

    $orgResponse = Invoke-NerdGraph '{ actor { organization { id name } } }'
    $orgId       = if ($orgResponse) { $orgResponse.data.actor.organization.id } else { $null }

    if (-not $orgId) {
        Log-Warn "Could not discover organization ID — skipping RBAC export"
        Save-Json -Data @() -Path (Join-Path $rbacDir "users.json")
        Save-Json -Data @() -Path (Join-Path $rbacDir "groups.json")
        return
    }
    Log-Debug "  Organization ID: $orgId"

    # Auth domains
    $domainsQuery = @"
{
  customerAdministration {
    authenticationDomains(filter: { organizationId: { eq: "$orgId" } }) {
      items { id name }
    }
  }
}
"@
    $domainsResponse = Invoke-NerdGraph $domainsQuery
    $domainIds       = if ($domainsResponse) {
        @($domainsResponse.data.customerAdministration.authenticationDomains.items | ForEach-Object { $_.id })
    } else { @() }
    Log-Debug "  Found $($domainIds.Count) authentication domain(s)"

    # Users per domain
    $allUsers = @()
    foreach ($domainId in $domainIds) {
        $cursor = $null
        do {
            $cursorArg = if ($cursor) { ", cursor: `"$cursor`"" } else { "" }
            $query = @"
{
  customerAdministration {
    users(filter: { authenticationDomainId: { eq: "$domainId" } }$cursorArg) {
      items { id name email timeZone authenticationDomainId }
      nextCursor
    }
  }
}
"@
            $response  = Invoke-NerdGraph $query
            $ud        = if ($response) { $response.data.customerAdministration.users } else { $null }
            $items     = if ($ud)       { @($ud.items) } else { @() }
            $cursor    = if ($ud)       { $ud.nextCursor } else { $null }
            $allUsers  = Merge-Arrays $allUsers $items
            Start-Sleep -Milliseconds $ApiDelayMs
        } while ($cursor)
    }

    Save-Json -Data $allUsers -Path (Join-Path $rbacDir "users.json")
    Log-Ok "  Exported $($allUsers.Count) users"

    # Groups
    Log-Info "  Exporting user groups..."
    $cursor    = $null
    $allGroups = @()
    do {
        $cursorArg = if ($cursor) { ", cursor: `"$cursor`"" } else { "" }
        $query = @"
{
  customerAdministration {
    groups(filter: { organizationId: { eq: "$orgId" } }$cursorArg) {
      items { id name authenticationDomainId }
      nextCursor
    }
  }
}
"@
        $response = Invoke-NerdGraph $query
        $gd       = if ($response) { $response.data.customerAdministration.groups } else { $null }
        $items    = if ($gd)       { @($gd.items) } else { @() }
        $cursor   = if ($gd)       { $gd.nextCursor } else { $null }
        $allGroups = Merge-Arrays $allGroups $items
        Start-Sleep -Milliseconds $ApiDelayMs
    } while ($cursor)

    Save-Json -Data $allGroups -Path (Join-Path $rbacDir "groups.json")
    Log-Ok "  Exported $($allGroups.Count) groups"
}

# =============================================================================
# USAGE ANALYTICS
# =============================================================================
function Invoke-NrqlQuery {
    param([string]$AccountId, [string]$NrqlQuery, [string]$OutputFile)

    $query = @"
{
  actor {
    account(id: $AccountId) {
      nrql(query: "$NrqlQuery") { results }
    }
  }
}
"@
    $response = Invoke-NerdGraph $query
    $results  = if ($response) { $response.data.actor.account.nrql.results } else { @() }
    Save-Json -Data $results -Path $OutputFile
}

function Generate-AnalyticsForAccount {
    param([string]$AccountId)

    $outDir = Join-Path $OutputDir "account_$AccountId/_usage_analytics"
    $null   = New-Item -ItemType Directory -Path $outDir -Force

    Log-Info "  [Account $AccountId] Generating usage analytics..."

    Invoke-NrqlQuery -AccountId $AccountId `
        -NrqlQuery "SELECT count(*) AS 'views', latest(timestamp) AS 'lastViewed' FROM NrAuditEvent WHERE actionIdentifier = 'dashboard.view' FACET targetId LIMIT MAX SINCE 90 days ago" `
        -OutputFile (Join-Path $outDir "dashboard_views.json")

    Invoke-NrqlQuery -AccountId $AccountId `
        -NrqlQuery "SELECT count(*) AS 'fired' FROM NrAiIncident FACET conditionName LIMIT MAX SINCE 90 days ago" `
        -OutputFile (Join-Path $outDir "alerts_most_fired.json")

    Invoke-NrqlQuery -AccountId $AccountId `
        -NrqlQuery "SELECT count(*) AS 'actions' FROM NrAuditEvent FACET actorEmail LIMIT 50 SINCE 90 days ago" `
        -OutputFile (Join-Path $outDir "users_most_active.json")

    Invoke-NrqlQuery -AccountId $AccountId `
        -NrqlQuery "SELECT bytecountestimate() / 1e9 AS 'daily_gb' FROM NrConsumption WHERE usageMetric = 'EventsBytes' FACET metric SINCE 30 days ago LIMIT MAX" `
        -OutputFile (Join-Path $outDir "ingest_by_data_type.json")

    Log-Ok "  [Account $AccountId] Generated 4 usage analytics files"
}

# =============================================================================
# MANIFEST & SUMMARY
# =============================================================================
function Generate-Manifest {
    param([array]$AllAccounts)

    Log-Info "Generating manifest..."

    $exportEndTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $duration      = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $ScriptStartEpoch

    $accountStats = @{}
    foreach ($aid in $AccountIdList) {
        $d = Join-Path $OutputDir "account_$aid"
        $accountStats[$aid] = @{
            dashboards               = Count-JsonFile (Join-Path $d "dashboards/dashboards.json")
            alert_policies           = Count-JsonFile (Join-Path $d "alerts/policies.json")
            nrql_conditions          = Count-JsonFile (Join-Path $d "alerts/nrql_conditions.json")
            synthetic_monitors       = Count-JsonFile (Join-Path $d "synthetics/monitors.json")
            workloads                = Count-JsonFile (Join-Path $d "workloads/workloads.json")
            service_level_indicators = Count-JsonFile (Join-Path $d "service_levels/indicators.json")
        }
    }

    $manifest = @{
        schema_version       = $SchemaVersion
        export_tool_version  = $ScriptVersion
        export_tool          = "dma-newrelic-export"
        export_timestamp     = $ScriptStartTime
        export_end_timestamp = $exportEndTime
        export_duration_seconds = $duration
        source_system = @{
            platform    = "New Relic"
            region      = $Region
            account_ids = $AccountIdList
        }
        export_options = @{
            dashboards     = [bool]$Dashboards
            alerts         = [bool]$Alerts
            synthetics     = [bool]$Synthetics
            workloads      = [bool]$Workloads
            service_levels = [bool]$ServiceLevels
            rbac           = [bool]$Rbac
            usage_analytics = [bool]$Usage
        }
        statistics = $accountStats
        accounts   = $AllAccounts
    }

    Save-Json -Data $manifest -Path (Join-Path $OutputDir "manifest.json")
    Log-Ok "Manifest generated"
}

function Generate-Summary {
    param([array]$AllAccounts)

    Log-Info "Generating export summary..."

    $exportEndTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $accountMap    = @{}
    foreach ($a in $AllAccounts) { $accountMap["$($a.id)"] = $a.name }

    $lines = @(
        "# DMA New Relic Export — Summary",
        "",
        "**Export Started:** $ScriptStartTime",
        "**Export Completed:** $exportEndTime",
        "**Tool Version:** $ScriptVersion",
        "**Region:** $Region",
        "",
        "## Accounts Exported",
        ""
    )
    foreach ($aid in $AccountIdList) {
        $name = if ($accountMap.ContainsKey($aid)) { $accountMap[$aid] } else { "Unknown" }
        $lines += "- **$aid** — $name"
    }

    $lines += @("", "## Export Statistics", "")
    foreach ($aid in $AccountIdList) {
        $name = if ($accountMap.ContainsKey($aid)) { $accountMap[$aid] } else { "Unknown" }
        $d    = Join-Path $OutputDir "account_$aid"
        $lines += @(
            "### Account $aid — $name",
            "",
            "- **Dashboards:** $(Count-JsonFile (Join-Path $d 'dashboards/dashboards.json'))",
            "- **Alert Policies:** $(Count-JsonFile (Join-Path $d 'alerts/policies.json'))",
            "- **NRQL Conditions:** $(Count-JsonFile (Join-Path $d 'alerts/nrql_conditions.json'))",
            "- **Synthetic Monitors:** $(Count-JsonFile (Join-Path $d 'synthetics/monitors.json'))",
            "- **Workloads:** $(Count-JsonFile (Join-Path $d 'workloads/workloads.json'))",
            "- **Service Level Indicators:** $(Count-JsonFile (Join-Path $d 'service_levels/indicators.json'))",
            ""
        )
    }

    $lines += @(
        "## Next Steps",
        "",
        "1. Upload this archive to the DMA New Relic App in your Dynatrace tenant",
        "2. Use the Dashboard Workspace to preview and translate NRQL queries to DQL",
        "3. Review alert conditions in the Alerts Workspace for Dynatrace equivalents",
        "4. Map New Relic workloads to Dynatrace Management Zones",
        "5. Review synthetic monitors in the Synthetics Workspace",
        "",
        "## Migration Mapping Reference",
        "",
        "| New Relic | Dynatrace Gen3 |",
        "|---|---|",
        "| Dashboard (NRQL widgets) | Dashboard (DQL tiles) |",
        "| NRQL query | DQL query |",
        "| Alert policy + NRQL condition | Metric event alert or DQL-based alert |",
        "| Synthetic monitor | Browser/HTTP monitor |",
        "| Workload | Management Zone |",
        "| Service level indicator | SLO |",
        "| Notification destination | Notification integration |"
    )

    Set-Content -Path (Join-Path $OutputDir "dma-env-summary.md") -Value ($lines -join "`n") -Encoding UTF8
    Log-Ok "Summary generated"
}

# =============================================================================
# ARCHIVE
# =============================================================================
function Create-Archive {
    Log-Info "Creating export archive..."

    $timestamp   = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $archiveName = "dma_export_newrelic_${timestamp}.tar.gz"

    if (Get-Command tar -ErrorAction SilentlyContinue) {
        $parentDir = Split-Path $OutputDir -Parent
        $baseName  = Split-Path $OutputDir -Leaf
        tar -czf $archiveName -C $parentDir $baseName 2>$null
    } else {
        # Fallback: use .NET compression (ZIP)
        $archiveName = "dma_export_newrelic_${timestamp}.zip"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($OutputDir, $archiveName)
    }

    $size = if (Test-Path $archiveName) { "{0:N1} MB" -f ((Get-Item $archiveName).Length / 1MB) } else { "unknown" }
    Log-Ok "Archive created: $archiveName ($size)"
    return $archiveName
}

# =============================================================================
# MAIN
# =============================================================================

# --TestAccess: probe permissions only, write nothing, exit with PASS/FAIL code.
if ($TestAccess) {
    exit (Invoke-TestAccess)
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  DMA New Relic Export v$ScriptVersion" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Log-Info "Region:   $Region"
Log-Info "Endpoint: $GraphqlEndpoint"
Log-Info "Output:   $OutputDir"
Log-Info "Accounts: $(if ($AccountIdList) { $AccountIdList -join ', ' } else { 'auto-discover' })"
Write-Host ""

# Write environment info
@{
    export_timestamp     = $ScriptStartTime
    export_tool          = "dma-newrelic-export"
    export_tool_version  = $ScriptVersion
    host = @{
        os         = [System.Environment]::OSVersion.Platform.ToString()
        os_version = [System.Environment]::OSVersion.VersionString
        hostname   = [System.Net.Dns]::GetHostName()
    }
} | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $OutputDir "_systeminfo/environment.json") -Encoding UTF8

# Account setup
if ($AccountIdList.Count -eq 0) { Discover-AccountIds }
$allAccounts = Export-Accounts
Write-Host ""

# Per-account exports
foreach ($accountId in $AccountIdList) {
    Write-Host "  Processing account: $accountId" -ForegroundColor Cyan
    $null = New-Item -ItemType Directory -Path (Join-Path $OutputDir "account_$accountId") -Force

    if ($Dashboards)     { Export-DashboardsForAccount     -AccountId $accountId }
    if ($Alerts)         { Export-AlertsForAccount         -AccountId $accountId }
    if ($Synthetics)     { Export-SyntheticsForAccount     -AccountId $accountId }
    if ($Workloads)      { Export-WorkloadsForAccount      -AccountId $accountId }
    if ($ServiceLevels)  { Export-ServiceLevelsForAccount  -AccountId $accountId }
    if ($Usage)          { Generate-AnalyticsForAccount    -AccountId $accountId }
    Write-Host ""
}

# Global exports
if ($Rbac) { Export-Users; Write-Host "" }

# Finalize
Generate-Manifest  -AllAccounts $allAccounts
Generate-Summary   -AllAccounts $allAccounts
$archiveName = Create-Archive

Write-Host ""
Write-Host "  ✓ Export complete!" -ForegroundColor Green
Write-Host "  Archive: $archiveName" -ForegroundColor White
Write-Host ""
Write-Host "  Next step: Upload $archiveName to the DMA New Relic App in Dynatrace." -ForegroundColor Blue
Write-Host ""

# Clean up staging directory
Remove-Item -Path $OutputDir -Recurse -Force -ErrorAction SilentlyContinue
