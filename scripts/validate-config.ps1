#Requires -Version 5.1
<#
.SYNOPSIS
Validates the gateway configuration WITHOUT touching a running gateway.

  1. every routing profile is well-formed (known routes, allowed targets)
  2. compatibility.json covers every route/target pair
  3. every profile renders with no leftover placeholder
  4. kong/kong.default.yml is exactly the rendering of mode-1-all-monolith
     and routes everything to the monolith
  5. Kong's own parser (kong config parse, same image as compose) accepts
     every rendered profile
  6. docker compose config is valid

Exit code 0 = all good. Needs Docker for step 5-6 (-SkipDocker skips them).
#>
[CmdletBinding()]
param([switch]$SkipDocker)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Gateway.psm1') -Force

$s = Get-GatewaySettings
$failures = New-Object System.Collections.Generic.List[string]
function Pass([string]$m) { Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $failures.Add($m) }

# Kong's own parser from the SAME base image the gateway is built from.
$kongImage = ([regex]::Match((Read-Utf8File (Join-Path $s.RepoRoot 'kong-image/Dockerfile')), '(?m)^FROM\s+(kong:\S+)')).Groups[1].Value
if (-not $kongImage) { throw 'Could not find FROM kong:<version> in kong-image/Dockerfile' }
if ($kongImage -match ':latest$') { Fail "Kong image must be pinned, found $kongImage" }

Write-Host 'Profiles'
$rendered = @{}
foreach ($name in Get-RoutingProfileNames) {
    try {
        $p = Get-RoutingProfile $name
        [void]@(Get-RoutingGuards $p.Routes)
        $rendered[$name] = ConvertTo-KongDeclarativeConfig $p.Routes
        Pass "$name renders"
    }
    catch { Fail "$name : $($_.Exception.Message)" }
}

Write-Host 'Default config'
$default = Get-RoutingProfile 'mode-1-all-monolith'
foreach ($r in Get-RouteNames) {
    if ($default.Routes[$r] -ne 'monolith') { Fail "mode-1-all-monolith routes $r to $($default.Routes[$r]); the default MUST be the monolith" }
}
if (-not (Test-Path -LiteralPath $s.DefaultConfig)) {
    Fail 'kong/kong.default.yml is missing (run scripts/render-config.ps1 -Name mode-1-all-monolith -OutFile kong/kong.default.yml)'
}
elseif (((Read-Utf8File $s.DefaultConfig) -replace "`r`n", "`n") -ne $rendered['mode-1-all-monolith']) {
    Fail 'kong/kong.default.yml is stale: re-render it from the template (scripts/render-config.ps1 -Name mode-1-all-monolith -OutFile kong/kong.default.yml)'
}
else { Pass 'kong/kong.default.yml == render(mode-1-all-monolith)' }

if (-not $SkipDocker) {
    # docker writes to stderr; under 'Stop' Windows PowerShell 5.1 would turn
    # the redirected stderr into a terminating error instead of a [FAIL] row.
    $ErrorActionPreference = 'Continue'
    Write-Host "Kong native validation ($kongImage kong config parse)"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("kong-validate-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        foreach ($name in $rendered.Keys | Sort-Object) {
            [System.IO.File]::WriteAllText((Join-Path $tmp "$name.yml"), $rendered[$name], (New-Object System.Text.UTF8Encoding($false)))
            $out = & docker run --rm -e KONG_DATABASE=off -v "${tmp}:/cfg:ro" $kongImage kong config parse "/cfg/$name.yml" 2>&1
            if ($LASTEXITCODE -eq 0) { Pass "$name : $(@($out)[-1])" } else { Fail "$name : $($out -join ' ')" }
        }
    }
    finally { Remove-Item -Recurse -Force $tmp }

    Write-Host 'docker compose config'
    Push-Location $s.RepoRoot
    try {
        $out = & docker compose config --quiet 2>&1
        if ($LASTEXITCODE -eq 0) { Pass 'docker-compose.yml is valid' } else { Fail "docker compose config: $($out -join ' ')" }
    }
    finally { Pop-Location }
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) validation failure(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'Configuration valid.' -ForegroundColor Green
