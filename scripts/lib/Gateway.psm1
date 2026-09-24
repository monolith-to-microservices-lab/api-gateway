# ---------------------------------------------------------------------------
# Gateway.psm1 - routing logic shared by every script in scripts/.
#
# Works on Windows PowerShell 5.1 (the lab's main shell) and PowerShell 7
# (CI on Linux). Keep it ASCII-only and free of 7-only syntax (no ternary,
# no ??, no -SkipHttpErrorCheck).
#
# Model
#   routing/profiles/*.json   versioned, named routing states (the "modes")
#   routing/compatibility.json guards derived from the API comparison
#   kong/kong.template.yml     the only hand-edited Kong config
#   state/routing.json         the APPLIED routing (local, not versioned)
#   state/kong.yml             the APPLIED rendered config Kong boots with
#   state/history.log          append-only audit of every switch
#
# A switch = render template -> POST /config (Kong validates and hot-swaps
# atomically, no restart, no dropped connections) -> verify the runtime ->
# persist state so a Kong restart keeps the same routing.
# ---------------------------------------------------------------------------
Set-StrictMode -Version 2.0

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:RouteNames = @('users-read', 'users-write', 'sales-read', 'sales-write')
$script:Placeholders = @{
    'users-read'  = '__USERS_READ_SERVICE__'
    'users-write' = '__USERS_WRITE_SERVICE__'
    'sales-read'  = '__SALES_READ_SERVICE__'
    'sales-write' = '__SALES_WRITE_SERVICE__'
}
$script:AllowedTargets = @{
    'users-read'  = @('monolith', 'user-service')
    'users-write' = @('monolith', 'user-service')
    'sales-read'  = @('monolith', 'sales-service')
    'sales-write' = @('monolith', 'sales-service')
}
$script:DefaultProfile = 'mode-1-all-monolith'

function Get-GatewaySettings {
    <# Paths and endpoints. Env vars let the integration tests drive a second,
       isolated gateway (other ports, other state dir) with the same scripts. #>
    $stateDir = $env:GATEWAY_STATE_DIR
    if (-not $stateDir) { $stateDir = Join-Path $script:RepoRoot 'state' }
    elseif (-not [System.IO.Path]::IsPathRooted($stateDir)) { $stateDir = Join-Path $script:RepoRoot $stateDir }

    $adminUrl = $env:GATEWAY_ADMIN_URL
    if (-not $adminUrl) { $adminUrl = 'http://127.0.0.1:8089' }
    $proxyUrl = $env:GATEWAY_PROXY_URL
    if (-not $proxyUrl) { $proxyUrl = 'http://localhost:8088' }
    $statusUrl = $env:GATEWAY_STATUS_URL
    if (-not $statusUrl) { $statusUrl = 'http://127.0.0.1:8090' }

    [pscustomobject]@{
        RepoRoot      = $script:RepoRoot
        ProfilesDir   = Join-Path $script:RepoRoot 'routing/profiles'
        Compatibility = Join-Path $script:RepoRoot 'routing/compatibility.json'
        Template      = Join-Path $script:RepoRoot 'kong/kong.template.yml'
        DefaultConfig = Join-Path $script:RepoRoot 'kong/kong.default.yml'
        StateDir      = $stateDir
        StateFile     = Join-Path $stateDir 'routing.json'
        StateConfig   = Join-Path $stateDir 'kong.yml'
        HistoryFile   = Join-Path $stateDir 'history.log'
        AdminUrl      = $adminUrl.TrimEnd('/')
        ProxyUrl      = $proxyUrl.TrimEnd('/')
        StatusUrl     = $statusUrl.TrimEnd('/')
    }
}

function Get-RouteNames { , $script:RouteNames }

function Read-Utf8File([string]$Path) {
    [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8FileAtomic([string]$Path, [string]$Content) {
    # temp file + move: a crash mid-write never leaves Kong a half file to boot.
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path
}

# --- Routing state -----------------------------------------------------------

function ConvertTo-RoutingState($Routes) {
    <# Normalise a hashtable / PSCustomObject into an ordered route->target map. #>
    $state = [ordered]@{}
    foreach ($name in $script:RouteNames) {
        $value = $null
        if ($Routes -is [System.Collections.IDictionary]) {
            if ($Routes.Contains($name)) { $value = $Routes[$name] }
        }
        elseif ($null -ne $Routes -and $Routes.PSObject.Properties[$name]) {
            $value = $Routes.PSObject.Properties[$name].Value
        }
        $state[$name] = $value
    }
    $state
}

function Test-RoutingState($State) {
    <# Returns a list of problems; empty list = valid. #>
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:RouteNames) {
        $target = $State[$name]
        if (-not $target) { $problems.Add("route '$name' has no target") ; continue }
        if ($script:AllowedTargets[$name] -notcontains $target) {
            $problems.Add("route '$name' cannot target '$target' (allowed: $($script:AllowedTargets[$name] -join ', '))")
        }
    }
    , $problems
}

function Get-RoutingProfileNames {
    $s = Get-GatewaySettings
    Get-ChildItem -LiteralPath $s.ProfilesDir -Filter '*.json' | Sort-Object Name | ForEach-Object { $_.BaseName }
}

function Get-RoutingProfile([string]$Name) {
    if ($Name -notmatch '^[a-z0-9][a-z0-9-]*$') { throw "Invalid profile name '$Name'." }
    $s = Get-GatewaySettings
    $path = Join-Path $s.ProfilesDir "$Name.json"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Unknown profile '$Name'. Available: $((Get-RoutingProfileNames) -join ', ')"
    }
    $json = Read-Utf8File $path | ConvertFrom-Json
    if ($json.name -ne $Name) { throw "Profile file $Name.json declares name '$($json.name)'." }
    $state = ConvertTo-RoutingState $json.routes
    $problems = Test-RoutingState $state
    if ($problems.Count -gt 0) { throw "Profile '$Name' is invalid: $($problems -join '; ')" }
    [pscustomobject]@{ Name = $json.name; Description = $json.description; Routes = $state }
}

function Get-DefaultRoutingState { (Get-RoutingProfile $script:DefaultProfile).Routes }

function Get-PersistedRouting {
    <# The routing Kong will boot with: state/routing.json, else the default. #>
    $s = Get-GatewaySettings
    if (Test-Path -LiteralPath $s.StateFile) {
        $json = Read-Utf8File $s.StateFile | ConvertFrom-Json
        $state = ConvertTo-RoutingState $json.routes
        $problems = Test-RoutingState $state
        if ($problems.Count -gt 0) { throw "state/routing.json is invalid: $($problems -join '; ')" }
        return [pscustomobject]@{ Source = 'state/routing.json'; Profile = $json.profile; AppliedAt = $json.applied_at; Routes = $state }
    }
    [pscustomobject]@{ Source = 'default (kong/kong.default.yml)'; Profile = $script:DefaultProfile; AppliedAt = $null; Routes = (Get-DefaultRoutingState) }
}

function Find-MatchingProfile($State) {
    foreach ($name in Get-RoutingProfileNames) {
        $p = Get-RoutingProfile $name
        $same = $true
        foreach ($r in $script:RouteNames) { if ($p.Routes[$r] -ne $State[$r]) { $same = $false } }
        if ($same) { return $name }
    }
    'custom'
}

# --- Guards --------------------------------------------------------------------

function Get-RoutingGuards($State) {
    <# One entry per route whose target carries a compatibility flag. #>
    $s = Get-GatewaySettings
    $compat = Read-Utf8File $s.Compatibility | ConvertFrom-Json
    $guards = New-Object System.Collections.Generic.List[object]
    foreach ($name in $script:RouteNames) {
        $target = $State[$name]
        $entry = $compat.routes.$name.targets.$target
        if ($null -eq $entry) { throw "compatibility.json has no entry for $name -> $target" }
        foreach ($flag in @($entry.flags)) {
            $guards.Add([pscustomobject]@{ Route = $name; Target = $target; Flag = $flag; Notes = $entry.notes })
        }
    }
    $guards.ToArray()   # callers wrap in @() - may be empty
}

function Assert-RoutingAllowed($State, $Current, [switch]$AcceptWriteDivergence, [switch]$AcceptIncompatibility) {
    <# Guards apply to routes whose target CHANGES. A risk accepted earlier (the
       route already points there) is not re-asked on every unrelated switch;
       going back to the monolith is never guarded. #>
    $guards = New-Object System.Collections.Generic.List[object]
    foreach ($g in @(Get-RoutingGuards $State)) {
        if ($Current[$g.Route] -ne $g.Target) { $guards.Add($g) }
    }
    $blocked = New-Object System.Collections.Generic.List[string]
    foreach ($g in $guards) {
        if ($g.Flag -eq 'write-cutover' -and -not $AcceptWriteDivergence) {
            $blocked.Add("$($g.Route) -> $($g.Target) is a WRITE CUTOVER. $($g.Notes) Re-run with -AcceptWriteDivergence only in a controlled test.")
        }
        elseif ($g.Flag -eq 'incompatible' -and -not $AcceptIncompatibility) {
            $blocked.Add("$($g.Route) -> $($g.Target) is KNOWN INCOMPATIBLE with the monolith API. $($g.Notes) Re-run with -AcceptIncompatibility to route anyway.")
        }
    }
    if ($blocked.Count -gt 0) {
        throw ("Routing change refused (nothing was applied):`n  - " + ($blocked -join "`n  - "))
    }
    $guards.ToArray()   # callers wrap in @() - may be empty
}

# --- Rendering -------------------------------------------------------------------

function ConvertTo-KongDeclarativeConfig($State) {
    $problems = Test-RoutingState $State
    if ($problems.Count -gt 0) { throw "Invalid routing state: $($problems -join '; ')" }
    $s = Get-GatewaySettings
    $text = Read-Utf8File $s.Template
    foreach ($name in $script:RouteNames) {
        $ph = $script:Placeholders[$name]
        if (-not $text.Contains($ph)) { throw "Template is missing placeholder $ph" }
        $text = $text.Replace($ph, $State[$name])
    }
    $left = [regex]::Matches($text, '__[A-Z_]+__')
    if ($left.Count -gt 0) { throw "Unrendered placeholder(s) in template: $(($left | ForEach-Object Value) -join ', ')" }
    $header = "# GENERATED from kong/kong.template.yml - do not edit.`n# routing: " +
        (($script:RouteNames | ForEach-Object { "$_=$($State[$_])" }) -join ' ') + "`n"
    $header + ($text -replace "`r`n", "`n")
}

# --- Admin API -----------------------------------------------------------------

function Invoke-GatewayHttp {
    <# HTTP call that never throws on 4xx/5xx. Returns Status (0 = unreachable),
       Body (string), Json (parsed or $null), Headers. #>
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [string]$Method = 'GET',
        [string]$Body,
        [string]$ContentType = 'application/json',
        [hashtable]$Headers = @{},
        [int]$TimeoutSec = 10
    )
    $params = @{ Uri = $Uri; Method = $Method; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; Headers = $Headers; ErrorAction = 'Stop' }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $params.ContentType = "$ContentType; charset=utf-8"
    }
    $status = 0; $content = ''; $respHeaders = @{}
    try {
        $r = Invoke-WebRequest @params
        $status = [int]$r.StatusCode
        $content = [string]$r.Content
        if ($r.Content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($r.Content) }
        $respHeaders = $r.Headers
    }
    catch {
        $resp = $null
        if ($_.Exception.PSObject.Properties['Response']) { $resp = $_.Exception.Response }
        if ($null -ne $resp) {
            $status = [int]$resp.StatusCode
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $content = $_.ErrorDetails.Message }
        }
        else {
            $content = $_.Exception.Message
        }
    }
    $json = $null
    if ($content -and ($content.TrimStart().StartsWith('{') -or $content.TrimStart().StartsWith('['))) {
        try { $json = $content | ConvertFrom-Json } catch { $json = $null }
    }
    [pscustomobject]@{ Status = $status; Body = $content; Json = $json; Headers = $respHeaders }
}

function Get-HeaderValue($Headers, [string]$Name) {
    if ($null -eq $Headers) { return $null }
    foreach ($k in @($Headers.Keys)) {
        if ($k -ieq $Name) { return (@($Headers[$k]) -join ',') }
    }
    $null
}

function Get-GatewayRuntimeRouting {
    <# Route -> service name as Kong is ACTUALLY routing right now. #>
    $s = Get-GatewaySettings
    $services = Invoke-GatewayHttp -Uri "$($s.AdminUrl)/services"
    if ($services.Status -ne 200) { throw "Admin API unreachable at $($s.AdminUrl) (status $($services.Status)): $($services.Body)" }
    $byId = @{}
    foreach ($svc in $services.Json.data) { $byId[$svc.id] = $svc.name }
    $routes = Invoke-GatewayHttp -Uri "$($s.AdminUrl)/routes"
    if ($routes.Status -ne 200) { throw "Admin API /routes failed (status $($routes.Status))" }
    $state = [ordered]@{}
    foreach ($name in $script:RouteNames) {
        $route = @($routes.Json.data | Where-Object { $_.name -eq $name }) | Select-Object -First 1
        if ($null -eq $route) { $state[$name] = $null }
        elseif ($null -eq $route.service) { $state[$name] = $null }
        else { $state[$name] = $byId[$route.service.id] }
    }
    $state
}

function Compare-RoutingState($A, $B) {
    foreach ($name in $script:RouteNames) { if ($A[$name] -ne $B[$name]) { return $false } }
    $true
}

# --- Apply ---------------------------------------------------------------------

function Enter-StateLock($Settings) {
    if (-not (Test-Path -LiteralPath $Settings.StateDir)) { New-Item -ItemType Directory -Path $Settings.StateDir | Out-Null }
    $lock = Join-Path $Settings.StateDir '.switch.lock'
    if (Test-Path -LiteralPath $lock) {
        $age = (Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime
        if ($age.TotalMinutes -lt 5) { throw "Another route switch is in progress ($lock). If it crashed, delete the file." }
        Write-Warning "Removing stale lock $lock ($([int]$age.TotalMinutes) min old)."
        Remove-Item -LiteralPath $lock -Force
    }
    $fs = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    [pscustomobject]@{ Path = $lock; Stream = $fs }
}

function Exit-StateLock($Lock) {
    if ($null -eq $Lock) { return }
    $Lock.Stream.Dispose()
    Remove-Item -LiteralPath $Lock.Path -Force -ErrorAction SilentlyContinue
}

function Set-GatewayRouting {
    <#
    .SYNOPSIS
    Applies a full routing state to the running gateway and persists it.
    Refuses write cutovers / known incompatibilities unless explicitly accepted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $State,
        [string]$Reason = '',
        [switch]$AcceptWriteDivergence,
        [switch]$AcceptIncompatibility,
        [switch]$DryRun
    )
    $s = Get-GatewaySettings
    $State = ConvertTo-RoutingState $State
    # Guards first, against the persisted (applied) state - a refused change
    # never reaches the Admin API.
    $persisted = Get-PersistedRouting
    $guards = @(Assert-RoutingAllowed $State $persisted.Routes -AcceptWriteDivergence:$AcceptWriteDivergence -AcceptIncompatibility:$AcceptIncompatibility)
    $config = ConvertTo-KongDeclarativeConfig $State
    $profileName = Find-MatchingProfile $State

    $before = Get-GatewayRuntimeRouting
    if (-not (Compare-RoutingState $before $persisted.Routes)) {
        Write-Warning 'DRIFT: the running gateway does not match the persisted routing (someone changed Kong outside these scripts?). The requested state will replace BOTH.'
        # ...and guard against what is really running too.
        $guards += @(Assert-RoutingAllowed $State $before -AcceptWriteDivergence:$AcceptWriteDivergence -AcceptIncompatibility:$AcceptIncompatibility)
        $guards = @($guards | Sort-Object Route, Flag -Unique)
    }

    Write-Host ''
    Write-Host ('Routing change -> profile: {0}' -f $profileName)
    foreach ($name in $script:RouteNames) {
        $mark = '  '
        if ($before[$name] -ne $State[$name]) { $mark = '* ' }
        Write-Host ('  {0}{1,-12} {2,-14} -> {3}' -f $mark, $name, $before[$name], $State[$name])
    }
    foreach ($g in $guards) { Write-Warning "ACCEPTED RISK [$($g.Flag)] $($g.Route) -> $($g.Target): $($g.Notes)" }
    foreach ($name in @('users-write', 'sales-write')) {
        if ($before[$name] -ne 'monolith' -and $State[$name] -eq 'monolith') {
            Write-Warning "$name goes back to the monolith. Rows written to $($before[$name]) while it owned writes are NOT in the monolith - a route rollback does not reconcile data (see docs/route-rollback-runbook.md)."
        }
    }
    if ($DryRun) { Write-Host 'Dry run: nothing applied.'; return }

    $lock = Enter-StateLock $s
    try {
        # Kong validates the whole document; on any error it keeps serving the
        # previous config untouched and answers 400 - so persist only after 201.
        $payload = @{ config = $config } | ConvertTo-Json -Compress
        $resp = Invoke-GatewayHttp -Uri "$($s.AdminUrl)/config" -Method POST -Body $payload -TimeoutSec 30
        if ($resp.Status -ne 201 -and $resp.Status -ne 200) {
            throw "Kong rejected the configuration (HTTP $($resp.Status)); the previous routing is still active. $($resp.Body)"
        }

        $deadline = (Get-Date).AddSeconds(15)
        do {
            $after = Get-GatewayRuntimeRouting
            if (Compare-RoutingState $after $State) { break }
            Start-Sleep -Milliseconds 300
        } while ((Get-Date) -lt $deadline)
        if (-not (Compare-RoutingState $after $State)) { throw 'Kong accepted the config but the runtime routes do not match the requested state.' }

        Write-Utf8FileAtomic $s.StateConfig $config
        $record = [ordered]@{
            profile    = $profileName
            routes     = $State
            applied_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            applied_by = [Environment]::UserName
            reason     = $Reason
        }
        Write-Utf8FileAtomic $s.StateFile (($record | ConvertTo-Json -Depth 5) + "`n")

        $changes = @($script:RouteNames | Where-Object { $before[$_] -ne $State[$_] } | ForEach-Object { "$_ $($before[$_])->$($State[$_])" })
        if ($changes.Count -eq 0) { $changes = @('no-op') }
        $line = '{0} user={1} profile={2} changes=[{3}] reason="{4}"' -f $record.applied_at, $record.applied_by, $profileName, ($changes -join ', '), ($Reason -replace '"', "'")
        [System.IO.File]::AppendAllText($s.HistoryFile, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    finally {
        Exit-StateLock $lock
    }
    Write-Host 'Applied (hot reload via Admin API /config - no restart) and persisted to state/.' -ForegroundColor Green
}

function Set-DomainRoute {
    <# Changes one domain's read and/or write route, keeping everything else. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('users', 'sales')] [string]$Domain,
        [Parameter(Mandatory)] [ValidateSet('Reads', 'Writes', 'All')] [string]$Scope,
        [Parameter(Mandatory)] [ValidateSet('monolith', 'service')] [string]$Target,
        [string]$Reason = '',
        [switch]$AcceptWriteDivergence,
        [switch]$AcceptIncompatibility,
        [switch]$DryRun
    )
    $service = 'monolith'
    if ($Target -eq 'service') {
        if ($Domain -eq 'users') { $service = 'user-service' } else { $service = 'sales-service' }
    }
    # Based on the persisted (applied) routing: the other domain keeps its
    # applied targets. Drift against the runtime is reported by Set-GatewayRouting.
    $state = ConvertTo-RoutingState (Get-PersistedRouting).Routes
    if ($Scope -in @('Reads', 'All')) { $state["$Domain-read"] = $service }
    if ($Scope -in @('Writes', 'All')) { $state["$Domain-write"] = $service }
    Set-GatewayRouting -State $state -Reason $Reason -AcceptWriteDivergence:$AcceptWriteDivergence -AcceptIncompatibility:$AcceptIncompatibility -DryRun:$DryRun
}

# --- Status / health -------------------------------------------------------------

function Get-UpstreamHealth([string]$Upstream) {
    <# Kong's active health check verdict for one backend: HEALTHY / UNHEALTHY /
       DNS_ERROR / UNKNOWN. Independent of whether Kong itself is up. #>
    $s = Get-GatewaySettings
    $r = Invoke-GatewayHttp -Uri "$($s.AdminUrl)/upstreams/$Upstream/health"
    if ($r.Status -ne 200 -or $null -eq $r.Json) { return 'UNKNOWN' }
    $t = @($r.Json.data) | Select-Object -First 1
    if ($null -eq $t) { return 'NO TARGET' }
    [string]$t.health
}

Export-ModuleMember -Function Get-GatewaySettings, Get-RouteNames, Get-RoutingProfileNames, Get-RoutingProfile,
    Get-DefaultRoutingState, Get-PersistedRouting, Find-MatchingProfile, Get-RoutingGuards, Assert-RoutingAllowed,
    ConvertTo-KongDeclarativeConfig, Invoke-GatewayHttp, Get-HeaderValue, Get-GatewayRuntimeRouting,
    Compare-RoutingState, Set-GatewayRouting, Set-DomainRoute, Get-UpstreamHealth, Test-RoutingState,
    ConvertTo-RoutingState, Write-Utf8FileAtomic, Read-Utf8File
