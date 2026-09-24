#Requires -Version 5.1
<#
.SYNOPSIS
Gateway health, checked piece by piece. "Kong is up" and "the backends are
healthy" are reported separately - one does not imply the other.

Backend health is Kong's own ACTIVE health-check verdict (it polls each
backend's /health from inside the Docker network), i.e. what the gateway
will actually do with the next request.

Exit code: 0 HEALTHY, 1 DEGRADED (a backend that currently receives traffic
is unhealthy, or telemetry is missing), 2 DOWN (Kong itself).

.EXAMPLE
.\scripts\health-check.ps1
.EXAMPLE
.\scripts\health-check.ps1 -PrometheusUrl http://localhost:9090
#>
[CmdletBinding()]
param(
    [string]$PrometheusUrl = 'http://localhost:9090',
    [string]$ExporterUrl = 'http://127.0.0.1:9542'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Gateway.psm1') -Force
$s = Get-GatewaySettings

$script:overall = 0   # 0 healthy, 1 degraded, 2 down
function Row([string]$Name, [string]$Value, [string]$Level = 'ok') {
    $color = @{ ok = 'Green'; warn = 'Yellow'; bad = 'Red'; info = 'Gray' }[$Level]
    Write-Host ('{0,-30} ' -f $Name) -NoNewline
    Write-Host $Value -ForegroundColor $color
}
function Degrade([int]$Level) { if ($Level -gt $script:overall) { $script:overall = $Level } }

Write-Host '===================================='
Write-Host ' API GATEWAY HEALTH'
Write-Host '===================================='
Write-Host ''

# --- Kong itself ------------------------------------------------------------
$proxy = Invoke-GatewayHttp -Uri "$($s.ProxyUrl)/gateway/health"
if ($proxy.Status -eq 200) { Row 'Kong proxy' 'UP' } else { Row 'Kong proxy' "DOWN ($($proxy.Status))" 'bad'; Degrade 2 }
$ready = Invoke-GatewayHttp -Uri "$($s.StatusUrl)/status/ready"
if ($ready.Status -eq 200) { Row 'Kong ready (config loaded)' 'UP' } else { Row 'Kong ready (config loaded)' "NOT READY ($($ready.Status))" 'bad'; Degrade 2 }
$admin = Invoke-GatewayHttp -Uri "$($s.AdminUrl)/"
if ($admin.Status -eq 200) { Row 'Admin API (127.0.0.1)' 'UP' } else { Row 'Admin API (127.0.0.1)' "UNREACHABLE ($($admin.Status))" 'bad'; Degrade 2 }

if ($script:overall -ge 2) {
    Write-Host ''
    Row 'OVERALL' 'DOWN' 'bad'
    exit 2
}

# --- Routing + backends -------------------------------------------------------
$runtime = Get-GatewayRuntimeRouting
$routedTo = @($runtime.Values | Sort-Object -Unique)
Write-Host ''
$labels = [ordered]@{ 'monolith' = 'Monolith'; 'user-service' = 'User Service'; 'sales-service' = 'Sales Service' }
foreach ($svc in $labels.Keys) {
    $h = Get-UpstreamHealth "$svc.upstream"
    $receives = $routedTo -contains $svc
    $suffix = ''
    if (-not $receives) { $suffix = '  (no route points here)' }
    if ($h -eq 'HEALTHY') { Row $labels[$svc] "UP$suffix" }
    elseif ($receives) { Row $labels[$svc] "DOWN - $h (RECEIVES TRAFFIC)" 'bad'; Degrade 1 }
    else { Row $labels[$svc] "DOWN - $h$suffix" 'warn' }
}

Write-Host ''
foreach ($route in Get-RouteNames) {
    $parts = $route.Split('-')
    $label = "/$($parts[0]) $($parts[1])s"
    $level = 'info'
    if ($runtime[$route] -ne 'monolith') { $level = 'warn' }
    Row "$label route" ($runtime[$route].ToUpper()) $level
}
$persisted = Get-PersistedRouting
if (Compare-RoutingState $runtime $persisted.Routes) { Row 'Persisted routing' "IN SYNC ($($persisted.Source))" }
else { Row 'Persisted routing' 'DRIFT (restart would change routing)' 'bad'; Degrade 1 }

# --- Telemetry -----------------------------------------------------------------
Write-Host ''
$metrics = Invoke-GatewayHttp -Uri "$($s.StatusUrl)/metrics"
if ($metrics.Status -eq 200 -and $metrics.Body -match 'kong_nginx_connections_total') { Row 'Kong metrics endpoint' 'UP' }
else { Row 'Kong metrics endpoint' "DOWN ($($metrics.Status))" 'bad'; Degrade 1 }

$exp = Invoke-GatewayHttp -Uri "$ExporterUrl/metrics"
if ($exp.Status -eq 200 -and $exp.Body -match 'gateway_route_upstream_info') { Row 'Route-state exporter' 'UP' }
else { Row 'Route-state exporter' "DOWN ($($exp.Status))" 'warn'; Degrade 1 }

$q = [uri]::EscapeDataString('up{job=~"api-gateway|gateway-route-exporter"}')
$prom = Invoke-GatewayHttp -Uri "$PrometheusUrl/api/v1/query?query=$q"
if ($prom.Status -eq 200 -and $prom.Json) {
    $targets = @($prom.Json.data.result)
    $upCount = @($targets | Where-Object { $_.value[1] -eq '1' }).Count
    if ($targets.Count -ge 2 -and $upCount -eq $targets.Count) { Row 'Prometheus scraping gateway' "UP ($upCount/$($targets.Count) targets)" }
    else { Row 'Prometheus scraping gateway' "PARTIAL ($upCount/$($targets.Count) targets up)" 'warn'; Degrade 1 }
}
else { Row 'Prometheus scraping gateway' 'Prometheus not reachable (observability stack down?)' 'warn' }

Write-Host ''
switch ($script:overall) {
    0 { Row 'OVERALL' 'HEALTHY' }
    1 { Row 'OVERALL' 'DEGRADED' 'warn' }
}
exit $script:overall
