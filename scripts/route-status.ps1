#Requires -Version 5.1
<#
.SYNOPSIS
Shows where each PATH + METHOD is routed RIGHT NOW (read from Kong's Admin API,
not from a file), whether that matches the persisted state, and gateway health.

.EXAMPLE
.\scripts\route-status.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Gateway.psm1') -Force

$s = Get-GatewaySettings
$methods = @{ read = 'GET, HEAD'; write = 'POST, PUT, PATCH, DELETE' }

Write-Host ''
Write-Host 'API GATEWAY ROUTING' -ForegroundColor Cyan
Write-Host ("proxy {0}   admin {1} (localhost only)" -f $s.ProxyUrl, $s.AdminUrl) -ForegroundColor DarkGray

try { $runtime = Get-GatewayRuntimeRouting }
catch {
    Write-Host ''
    Write-Host "Gateway: DOWN - $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}
$persisted = Get-PersistedRouting

foreach ($domain in @('users', 'sales')) {
    Write-Host ''
    Write-Host "/$domain" -ForegroundColor White
    foreach ($scope in @('read', 'write')) {
        $route = "$domain-$scope"
        $target = $runtime[$route]
        $color = 'Yellow'
        if ($target -eq 'monolith') { $color = 'Gray' }
        if (-not $target) { $target = '(route missing!)'; $color = 'Red' }
        Write-Host ('  {0,-26} -> ' -f $methods[$scope]) -NoNewline
        Write-Host ('{0,-15}' -f $target) -ForegroundColor $color -NoNewline
        Write-Host (" [route $route]") -ForegroundColor DarkGray
    }
}

Write-Host ''
$profileName = Find-MatchingProfile $runtime
Write-Host ('Profile   : {0}' -f $profileName)
$applied = ''
if ($persisted.AppliedAt) { $applied = " (applied $($persisted.AppliedAt))" }
if (Compare-RoutingState $runtime $persisted.Routes) {
    Write-Host ('Persisted : {0}{1} - in sync' -f $persisted.Source, $applied)
}
else {
    Write-Host ('Persisted : {0}{1} - DRIFT: a Kong restart would change the routing!' -f $persisted.Source, $applied) -ForegroundColor Red
}

$status = Invoke-GatewayHttp -Uri "$($s.StatusUrl)/status/ready"
$root = Invoke-GatewayHttp -Uri "$($s.AdminUrl)/"
$version = ''
if ($root.Json) { $version = " (Kong $($root.Json.version))" }
if ($status.Status -eq 200) { Write-Host "Gateway   : HEALTHY$version" -ForegroundColor Green }
else { Write-Host "Gateway   : NOT READY (status API $($status.Status))$version" -ForegroundColor Red }

$upstreams = [ordered]@{ 'monolith' = 'monolith.upstream'; 'user-service' = 'user-service.upstream'; 'sales-service' = 'sales-service.upstream' }
$line = @()
foreach ($k in $upstreams.Keys) { $line += "$k=$(Get-UpstreamHealth $upstreams[$k])" }
Write-Host ('Upstreams : {0}' -f ($line -join '  '))
Write-Host ''
